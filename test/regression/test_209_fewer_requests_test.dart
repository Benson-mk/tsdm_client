/// Roadmap: fewer requests.
///
/// * Poll card: the thread page already holds the poll form (`form#poll` in the first floor), the formhash of the
///   account the page was served to included. Every poll card asked the forum for the whole thread page again when it
///   was created (twice: the account status replayed to its new listener loaded it once more), and again on every
///   account status, although the thread page reloads for a new account since 1.37.0 and builds its floors afresh.
///   The card now shows the form of the page; it asks the forum only when the page does not hold it, or holds it for
///   another account. Voting still asks once for the results.
/// * Points and bank pages are asked in the JSON mode of the forum's app API (`tsdmapp=json`, plugin 1.7.0); an older
///   plugin ignores the parameter and the web page comes back. Both give the same, the forms are posted as before.
///
/// The forum pages are synthetic (grounded in the Discuz templates), no real account or network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:universal_html/parsing.dart';

import 'tsdmapp_page_cut.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

const _tid = 1264975;

/// The check page of the account switch as served to a logged-in [user].
String _authedPage(UserLoginInfo user) =>
    '<html><body><div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a> '
    '</strong></div><input type="hidden" name="formhash" value="XXXXXXXX" /></body></html>';

/// Cookie row in the format the persistent cookie jar reads back: the auth cookie is sent with every request.
Map<String, String> _cookieOf(UserLoginInfo user) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${user.username!.toLowerCase()}; Path=/;_crt=1"}}',
};

/// The poll form of test 083 ([name]: `multiple` open for votes, `voted` with results) for the thread of this test,
/// with [formHash]; without the identity script of the fixture, the page declares it.
String _pollForm(String name, String formHash) =>
    File(
          'test/data/poll_${name}_x5.html',
        )
        .readAsStringSync()
        .replaceFirst(RegExp('<script>.*?</script>'), '')
        .replaceAll('XXXXXXXX', formHash)
        .replaceAll(
          'tid=1266029',
          'tid=$_tid',
        );

/// A thread page served to [uid] with the poll form [poll] in its first floor, open for replies.
String _threadHtml(int uid, String poll) =>
    '''
<!DOCTYPE html>
<html><head><title>Poll title - Powered by Discuz!</title>
<link href="$baseUrl/forum.php?mod=viewthread&amp;tid=$_tid" rel="canonical" />
<script type="text/javascript">var STYLEID = '2', STATICURL = 'static/', discuz_uid = '$uid', cookiepre = 'x_';</script>
</head><body>
<div id="wp" class="wp">
<div id="postlist"><h1 class="ts"><span id="thread_subject">Poll title</span></h1><div class="bm">
<div id="post_1"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=1"><em>1</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Alice</a></div></div>
<div class="pct"><div class="pcb"><div class="pcbs">
<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">floor 1 text</td></tr></table>
$poll
</div></div></div></td>
</tr></tbody></table></div>
</div></div>
<form method="post" autocomplete="off" name="modactions" id="modactions"></form>
<form method="post" id="fastpostform" action="forum.php?mod=post&amp;action=reply&amp;fid=4&amp;tid=$_tid&amp;replysubmit=yes">
<input type="hidden" name="formhash" value="${uid == 0 ? 'none' : 'hashOf$uid'}" />
<input type="hidden" name="posttime" value="1760000000" />
<input type="hidden" name="subject" value="" />
<div class="area"><textarea name="message"></textarea></div>
</form>
</div>
<div id="ft" class="wp cl">Footer</div>
</body></html>''';

/// The forum of the thread: its page for the account whose cookie came with the request, in JSON mode when [json] (as
/// the app API plugin answers it) and asked for; takes votes. Records every request.
final class _PollForum implements HttpClientAdapter {
  _PollForum({this.json = false});

  final bool json;

  /// The accounts that voted.
  final voted = <int>{};

  /// Every request, with the form it posted.
  final requests = <RequestOptions>[];
  final bodies = <String?>[];

  /// Holds the answers back while set.
  Completer<void>? gate;

  /// Thread page loads of the thread page itself.
  int get threadLoads =>
      requests.where((r) => r.method == 'GET' && r.uri.queryParameters['mod'] == 'viewthread').length;

  /// Thread pages asked for by a poll card (the `findpost` redirect of its floor).
  int get pollLoads => requests.where((r) => r.method == 'GET' && r.uri.queryParameters['goto'] == 'findpost').length;

  /// The votes posted, as their forms.
  List<Map<String, String>> get votes => [
    for (final (i, r) in requests.indexed)
      if (r.method == 'POST' && r.uri.queryParameters['action'] == 'votepoll') Uri.splitQueryString(bodies[i]!),
  ];

  static int _uidOf(RequestOptions options) {
    final cookie = '${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}';
    return cookie.contains('auth=bob') ? _bob.uid! : (cookie.contains('auth=alice') ? _alice.uid! : 0);
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(requestStream == null ? null : utf8.decode(await requestStream.expand((e) => e).toList()));
    if (gate != null) {
      await gate!.future;
    }
    final uid = _uidOf(options);
    if (options.method == 'POST') {
      expect(options.uri.queryParameters['action'], 'votepoll', reason: 'the only form posted here is the vote');
      expect(options.uri.queryParameters['tsdmapp'], isNull, reason: 'a form is posted as before');
      voted.add(uid);
      return ResponseBody.fromString(
        '<html><body>Accepted</body></html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    final html = _threadHtml(uid, _pollForm(voted.contains(uid) ? 'voted' : 'multiple', 'hashOf$uid'));
    final asJson = json && options.uri.queryParameters['tsdmapp'] == 'json';
    return ResponseBody.fromString(
      asJson ? pageAnswerOf(html, 'viewthread') : html,
      200,
      headers: {
        Headers.contentTypeHeader: [if (asJson) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The forum as seen by the isolated client of the account switch: the check page of Bob.
final class _SwitchAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    _authedPage(_bob),
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// Avatars are not downloaded in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Notification bloc holding a fixed state; the thread page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  @override
  void add(NotificationEvent event) {}

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Frames with real time in between: the database and its streams answer on the real event loop.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Lets the snack bar and the database stream timers fire before the framework checks for pending timers.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

/// Choose the first option of the card and send the vote.
Future<void> _vote(WidgetTester tester) async {
  await tester.tap(_inCard(find.byType(CheckboxListTile)).first);
  await tester.pump();
  await tester.tap(_inCard(find.byType(FilledButton)));
  await _settle(tester);
}

/// A forum of the thread for the app's default client, bound to the account in use like the app's.
_PollForum _useForum({bool json = false}) {
  final forum = _PollForum(json: json);
  getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  );
  return forum;
}

/// The poll of the first floor of the thread page served to [uid], as the thread parser keeps it.
PostPoll _pagePoll(int uid, {String name = 'multiple'}) => parseThreadDocument(
  parseHtmlDocument(_threadHtml(uid, _pollForm(name, 'hashOf$uid'))),
  1,
).postList.single.poll!;

final Finder _card = find.byType(PollCard);

Finder _inCard(Finder matching) => find.descendant(of: _card, matching: matching);

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late AuthenticationRepository auth;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    // Alice is logged in on this device, Bob is saved too.
    for (final user in [_alice, _bob]) {
      await storage.saveCookie(username: user.username!, uid: user.uid!, cookie: _cookieOf(user));
    }
    await settings.setValue<int>(SettingsKeys.loginUid, 1000);
    await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
    getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)));
    auth = AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _SwitchAdapter(),
        cookie: cookie,
      ),
    );
    // The account status of a running app: a new listener gets it at once.
    final login = await auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run();
    expect(login.isRight(), isTrue, reason: '$login');
  });

  tearDown(() async {
    await auth.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  group('poll card in the thread page', () {
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;

    setUp(() {
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      ThreadAuthorCache.clear();
    });

    tearDown(() async {
      await settingsBloc.close();
      await blocks.dispose();
    });

    /// The thread page; `/other` is a plain page to push above it. Returns the router.
    Future<GoRouter> pumpThread(WidgetTester tester, _PollForum forum) async {
      // Tall enough for the floor and the whole card.
      tester.view
        ..physicalSize = const Size(1000, 3000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final info = NotificationInfoRepository();
      final counts = NotificationStateCubit(info);
      final cubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.effectiveCurrentUid,
        authStatus: auth.status,
      );
      final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const ThreadPage(
              threadID: '$_tid',
              findPostID: null,
              pageNumber: '1',
              overrideReverseOrder: false,
              overrideWithExactOrder: null,
            ),
          ),
          GoRoute(
            path: '/other',
            builder: (_, _) => const Scaffold(body: Center(child: Text('other page'))),
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        await cubit.close();
        await history.close();
        await info.dispose();
        await counts.close();
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: cubit),
                BlocProvider<NotificationBloc>.value(value: _Notifications()),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
              ],
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(forum.threadLoads, 1, reason: 'opening the page loads it once');
      return router;
    }

    Future<void> switchToBob(WidgetTester tester) async {
      final result = await tester.runAsync(() => auth.switchUser(_bob).run());
      expect(result!.isRight(), isTrue, reason: '$result');
      await _settle(tester);
    }

    for (final json in [false, true]) {
      final mode = json ? 'JSON answer' : 'web page';
      testWidgets('$mode: the card shows the form of the page, no request of its own; a vote asks once', (
        tester,
      ) async {
        final forum = _useForum(json: json);
        await pumpThread(tester, forum);
        expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5), reason: 'the form of the page, open');
        expect(_inCard(find.text('Selected 0 / 2')), findsOneWidget);
        expect(forum.pollLoads, 0, reason: 'the page holds the form, the card asks nothing');

        await _vote(tester);
        expect(forum.votes, hasLength(1));
        expect(forum.votes.single['formhash'], 'hashOf1000', reason: 'the formhash of the page, served to Alice');
        expect(forum.votes.single['pollanswers[0]'], '40028');
        expect(forum.pollLoads, 1, reason: 'the results are asked once after the vote');
        expect(_inCard(find.text('50.00% (1)')), findsNWidgets(2), reason: 'the results of the answer');
        expect(_inCard(find.text(t.pollVoting.voted)), findsOneWidget);
        expect(_inCard(find.text(t.pollVoting.unconfirmed)), findsNothing);
        expect(forum.threadLoads, 1);
        await _dispose(tester);
      });
    }

    testWidgets('an account switch reloads the thread page only: the card shows its form, no request of its own', (
      tester,
    ) async {
      final forum = _useForum(json: true);
      await pumpThread(tester, forum);
      expect(forum.pollLoads, 0);

      await switchToBob(tester);
      expect(forum.threadLoads, 2, reason: 'the thread page reloads for Bob');
      expect(forum.pollLoads, 0, reason: 'no card asks for the page the thread page just loaded');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));

      await _vote(tester);
      expect(forum.votes.single['formhash'], 'hashOf1001', reason: "Bob's vote goes out with Bob's formhash");
      expect(forum.voted, {_bob.uid});
      expect(forum.pollLoads, 1);
      expect(_inCard(find.text('50.00% (1)')), findsNWidgets(2));
      await _dispose(tester);
    });

    testWidgets('a thread page under another page: no request while covered, the reload once shown again', (
      tester,
    ) async {
      final forum = _useForum(json: true);
      final router = await pumpThread(tester, forum);
      unawaited(router.push('/other'));
      await _settle(tester);

      await switchToBob(tester);
      expect(forum.threadLoads, 1, reason: 'not reloaded while covered');
      expect(forum.pollLoads, 0, reason: 'nor the poll');

      router.pop();
      await _settle(tester);
      expect(forum.threadLoads, 2);
      expect(forum.pollLoads, 0);
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      await _dispose(tester);
    });
  });

  group('poll form of the page', () {
    test('the thread parser keeps the form of the floor and the account the page was served to', () {
      final html = _threadHtml(_alice.uid!, _pollForm('multiple', 'hashOf1000'));
      for (final document in [parseHtmlDocument(html), tsdmAppPageDocument(pageAnswerOf(html, 'viewthread'))]) {
        final post = parseThreadDocument(document, 1).postList.single;
        expect(post.hasPoll, isTrue);
        expect(post.poll!.viewerUid, _alice.uid, reason: 'the JSON answer keeps the discuz_uid script of the head');
        expect(post.poll!.form, startsWith('<form id="poll"'));
        expect(post.poll!.form, contains('value="hashOf1000"'));
      }
      expect(parseThreadDocument(parseHtmlDocument(_threadHtml(0, '')), 1).postList.single.poll, isNull);
    });

    test('the form of a page served to another account is not shown, its formhash is not that of the account', () {
      final cubit = PollCubit(
        url: 'poll',
        currentUid: () => _bob.uid,
        repository: () => PollRepository(getPage: (_) async => fail('no request'), postForm: (_, _) async => ''),
      );
      addTearDown(cubit.close);
      final page = _pagePoll(_alice.uid!);
      expect(cubit.adopt(page.form, servedUid: page.viewerUid), isFalse);
      expect(cubit.state.poll, isNull);
      final own = _pagePoll(_bob.uid!);
      expect(cubit.adopt(own.form, servedUid: own.viewerUid), isTrue);
      expect(cubit.state.poll!.availability, PollAvailability.available);
      expect(cubit.state.poll!.formHash, 'hashOf1001');
      expect(cubit.state.uid, _bob.uid);
    });

    test('a guest page for an account in use: login required, as the same page asked again would say', () {
      final cubit = PollCubit(
        url: 'poll',
        currentUid: () => _alice.uid,
        repository: () => PollRepository(getPage: (_) async => fail('no request'), postForm: (_, _) async => ''),
      );
      addTearDown(cubit.close);
      expect(cubit.adopt(_pollForm('multiple', 'none'), servedUid: null), isTrue);
      expect(cubit.state.poll!.availability, PollAvailability.loginRequired);
    });

    test('a vote from the form of the page is posted once, then the results are asked once', () async {
      var gets = 0;
      final sent = <Map<String, String>>[];
      final cubit = PollCubit(
        url: 'poll',
        currentUid: () => _alice.uid,
        repository: () => PollRepository(
          getPage: (_) async {
            gets++;
            return File('test/data/poll_voted_x5.html').readAsStringSync();
          },
          postForm: (_, body) async {
            sent.add(body);
            return '';
          },
        ),
      );
      addTearDown(cubit.close);
      final page = _pagePoll(_alice.uid!);
      expect(cubit.adopt(page.form, servedUid: page.viewerUid), isTrue);
      expect(gets, 0);
      cubit.select('40029', selected: true);
      await cubit.submit();
      expect(sent.single, {'formhash': 'hashOf1000', 'pollsubmit': 'true', 'pollanswers[0]': '40029'});
      expect(gets, 1);
      expect(cubit.state.poll!.availability, PollAvailability.voted);
      expect(cubit.state.submissionUnconfirmed, isFalse);
    });
  });

  group('poll card outside the thread page (the post of a notice)', () {
    Future<void> pumpCard(WidgetTester tester, PostPoll? fromPage) async {
      tester.view
        ..physicalSize = const Size(1000, 3000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: PollCard('1', fromPage: fromPage)),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    testWidgets('the form of the page: no request, also not for the account status a new listener gets', (
      tester,
    ) async {
      final forum = _useForum();
      await pumpCard(tester, _pagePoll(_alice.uid!));
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      expect(forum.requests, isEmpty);
      await _dispose(tester);
    });

    testWidgets('nothing reloads the post here: the card loads once for a new account, with its form', (
      tester,
    ) async {
      final forum = _useForum();
      await pumpCard(tester, _pagePoll(_alice.uid!));
      final result = await tester.runAsync(() => auth.switchUser(_bob).run());
      expect(result!.isRight(), isTrue, reason: '$result');
      await _settle(tester);
      expect(forum.pollLoads, 1, reason: 'one load for Bob');
      expect(forum.requests, hasLength(1));
      await _vote(tester);
      expect(forum.votes.single['formhash'], 'hashOf1001');
      expect(forum.pollLoads, 2, reason: 'and once for the results');
      await _dispose(tester);
    });

    testWidgets('the same account reported again loads nothing', (tester) async {
      final forum = _useForum();
      await pumpCard(tester, _pagePoll(_alice.uid!));
      await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      await _settle(tester);
      expect(forum.requests, isEmpty);
      await _dispose(tester);
    });

    for (final (name, page) in [
      ('a page served to another account', () => _pagePoll(_bob.uid!)),
      ('no form of the page', () => null),
    ]) {
      testWidgets('$name: the card asks the forum once', (tester) async {
        final forum = _useForum();
        await pumpCard(tester, page());
        expect(forum.pollLoads, 1, reason: 'once, not again for the account status a new listener gets');
        expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
        await _dispose(tester);
      });
    }
  });
}
