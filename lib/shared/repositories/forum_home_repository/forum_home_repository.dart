import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/red_packet/repository/daily_rewards_repository.dart';
import 'package:tsdm_client/features/red_packet/repository/red_packet_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// A repository that fetches the homepage (`forum.php`) from the forum.
///
/// One instance serves the whole app: the homepage tab, the topics tab and the activities page share the same
/// `forum.php` page, so every fetch is published on [pageStream] and both tabs can re-parse it (issue #1: a favorite
/// forum added on the web only showed up after a refresh on the topics tab itself).
///
/// The page is asked in the JSON mode of the forum's app API. An answer of plugin 2.3.0 or later carries the page as
/// structured fields (`schema: 5`) and is kept as such ([ForumHomeApiPage]), its `document` never read (a lean
/// answer, `nodoc=1`, has none); any other answer (a web page from a forum without the plugin, an older plugin's
/// answer, whose `document` holds the blocks of the page) is kept as its document ([ForumHomeWebPage]), parsed as
/// the web page always was.
///
/// **Need to call dispose.**
final class ForumHomeRepository with LoggerMixin {
  final _dailyRewards = DailyRewardsRepository();

  /// Cached page of the forum homepage.
  ForumHomePage? _page;

  /// Every page fetched from the server, the latest one replayed to new listeners.
  final _pageSubject = BehaviorSubject<ForumHomePage>();

  /// Stream of every `forum.php` page fetched from the server, in order; a new listener gets the latest one first
  /// when there is any.
  Stream<ForumHomePage> get pageStream => _pageSubject.stream;

  /// Check has cached [_page] or not.
  bool hasCache() => _page != null;

  /// Get the cached [_page].
  ForumHomePage? getCache() => _page;

  /// Drop the cached page so the next fetch goes to the server.
  void invalidate() => _page = null;

  /// Release the stream.
  Future<void> dispose() async {
    await _pageSubject.close();
  }

  /// Fetch the home page of app from server.
  AsyncEither<ForumHomePage> fetchHomePage({bool force = false}) => AsyncEither(() async {
    debug('fetch home page');
    if (!force && _page != null) {
      debug('use cached home page');
      return right(_page!);
    }

    final pageEither = await _fetchForumHome().run();
    if (pageEither.isLeft()) {
      return left(pageEither.unwrapErr());
    }

    final page = pageEither.unwrap();
    _page = page;
    if (!_pageSubject.isClosed) {
      _pageSubject.add(page);
    }
    debug('use fetched home page');
    return right(page);
  });

  /// Fetch the topic page of app from server.
  ///
  /// The topics tab shows the same `forum.php` as the homepage, so this is the same cache and the same fetch.
  AsyncEither<ForumHomePage> fetchTopicPage({bool force = false}) => fetchHomePage(force: force);

  /// Ask [client] for the [homePage] once: the structured answer of plugin 2.3.0 ([indexApiAnswerOf]), or the
  /// document of any other answer.
  ///
  /// An answer without a page ([tsdmAppAnswerWithoutPage]: the plugin failed to build it, or an empty body) is a
  /// failed request, not a forum without boards.
  static Future<Either<AppException, ForumHomePage>> _askPage(NetClientProvider client) async {
    switch (await client.get(withTsdmAppJson(homePage)).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        if (value.statusCode != HttpStatus.ok) {
          return left(HttpRequestFailedException(value.statusCode));
        }
        final api = indexApiAnswerOf(value.data);
        if (api != null) {
          return right(ForumHomeApiPage(api));
        }
        if (tsdmAppAnswerWithoutPage(value.data)) {
          return left(HttpRequestFailedException(value.statusCode));
        }
        // A JSON answer kept as its document (an older plugin's, the cached guest index of plugin 2.3.0) may name
        // the checknewpm script its blocks do not hold.
        final checknewpm = tsdmAppAnswerJson(value.data)?['checknewpm'];
        return right(
          ForumHomeWebPage(tsdmAppPageDocument(value.data), checknewpm: checknewpm is String ? checknewpm : null),
        );
    }
  }

  /// Fetch the [homePage] of forum.
  ///
  /// # Exception
  ///
  /// * [HttpHandshakeFailedException] if GET request failed.
  AsyncEither<ForumHomePage> _fetchForumHome() => AsyncEither(() async {
    // Keep every follow-up on the same identity-bound client, including after an account switch.
    final client = getIt.get<NetClientProvider>();
    final cookie = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>() : null;
    final uid = cookie?.userLoginInfo.uid;
    // JSON mode of the forum's app API when the forum has it (see TsdmAppApi); the web page otherwise.
    final first = await _askPage(client);
    if (first.isLeft()) return first;
    final page = first.unwrap();
    bool isCurrent() => cookie?.userLoginInfo.uid == uid;
    final refresh = await _dailyRewards.processFields(
      servedUid: page.servedUid,
      visitUri: page.dailyVisitUri,
      packet: page.dailyRedPacket,
      formHash: page.formHash,
      uid: uid,
      isCurrent: isCurrent,
      autoClaimEnabled: () =>
          getIt.isRegistered<SettingsRepository>() &&
          getIt.get<SettingsRepository>().currentSettings.autoDailyRedPacket,
      visit: (uri) async {
        final result = await client.getUri(uri).run();
        return result.fold(
          (_) => false,
          // Stock checknewpm answers an empty JavaScript response. A login/error page is not a successful visit.
          (response) => response.statusCode == 200 && '${response.data ?? ''}'.trim().isEmpty,
        );
      },
      claim: (formHash) async =>
          (await const RedPacketRepository().claimDaily(formHash: formHash, client: client).run()).fold(
            (_) => null,
            (value) => value,
          ),
    );
    if (refresh && isCurrent()) {
      // Not recursive: one best-effort reload updates the balance and removes the claimed packet entry.
      try {
        final updated = await _askPage(client);
        if (updated.isRight() && isCurrent() && updated.unwrap().servedUid == uid) return updated;
      } on Object {
        warning('daily rewards homepage reload failed; keep the original page');
      }
    }
    if (!isCurrent()) return left(IdentityChangedException());
    return first;
  });
}
