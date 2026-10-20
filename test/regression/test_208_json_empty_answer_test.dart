/// A forum page asked in the JSON mode (`tsdmapp=json`) and answered with an empty body is a failed request.
///
/// dio reads an empty `application/json` body as null, and `tsdmAppPageDocument` turned that into an empty document:
/// the board, the homepage, my threads, the favorites, the friends, the search, the chat history, the profile… showed
/// an empty list, the achievements, the title shop and the poll card asked the user to log in, none of them the
/// "failed to load" with its retry that a network error gives. PR #188 fixed the notifications, the draft box and the
/// thread page; every other caller of the JSON mode is checked here the same way.
///
/// For each caller, four things hold:
///
/// * a network error is a failure (the state every other failure is shown as);
/// * an answer without a page is that same failure: an empty body (served as JSON, read as null; a JSON `null`; served
///   as a web page, read as an empty string), a blank web page, and `{"ok":0,"error":"internal"}` (the plugin failed to
///   build the page);
/// * an ordinary answer with an empty list is not a failure, and is the same as the web page served for it;
/// * a forum message (`{"ok":0,"error":"message","document":…}`: no permission, please log in) is a page too: it gives
///   the same as the web page of that message, as it always did.
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
import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/achievements/view/achievements_page.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/draft_box/repository/draft_repository.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/medal_center/view/medal_center_page.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/profile/repository/my_titles_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/title_shop/repository/title_shop_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:universal_html/html.dart' as uh;

const _uid = 1000;

/// A Discuz X5 page around [main], the frame the plugin's answer is cut from. Synthetic names and ids only.
String _page(String main) =>
    '''
<!DOCTYPE html>
<html><head><meta charset="utf-8" /><title>Synthetic - Powered by Discuz!</title>
<script type="text/javascript">var STYLEID = '2', STATICURL = 'static/', discuz_uid = '$_uid', cookiepre = 'x_';</script>
</head><body>
<div id="hd"><div class="wp"><div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=$_uid">Alice</a></strong></p></div></div></div>
<div id="wp" class="wp">
$main
</div>
<div id="ft" class="wp cl">Footer</div>
</body></html>''';

/// The page of a guest around [main]: no user node, `discuz_uid` 0.
String _guestPage(String main) =>
    '''
<!DOCTYPE html>
<html><head><meta charset="utf-8" /><title>Synthetic - Powered by Discuz!</title>
<script type="text/javascript">var STYLEID = '2', STATICURL = 'static/', discuz_uid = '0', cookiepre = 'x_';</script>
</head><body>
<div id="hd"><div class="wp"><div id="lsform">login</div></div></div>
<div id="wp" class="wp">
$main
</div>
<div id="ft" class="wp cl">Footer</div>
</body></html>''';

/// What the plugin answers a page whose blocks are [blocks]: the `discuz_uid` script of the page head and the blocks.
Map<String, Object?> _answer(String blocks, {bool ok = true, String? error}) => {
  'ok': ok ? 1 : 0,
  'error': ?error,
  'api': 1,
  'head': '<script type="text/javascript">var discuz_uid = \'$_uid\';</script>',
  'document': blocks,
};

/// A page with a list that is empty: the page of every caller is this, whatever its list is.
const _emptyBlocks = '<div id="pt" class="bm cl"></div><div id="ct" class="ct2_a wp cl"><div class="mn"></div></div>';

/// A forum message the web page shows for a request it refuses.
const _deniedBlocks = '<div id="messagetext" class="alert_info"><p>抱歉，您没有权限访问该内容</p></div>';

/// The same refusal as Discuz! classes it by default (`alert_error`), the page [tsdmAppMessageDocument] rebuilds.
const _deniedErrorBlocks = '<div id="messagetext" class="alert_error"><p>抱歉，您没有权限访问该内容</p></div>';

/// The forum's message answered without its blocks (plugin 2.3.0 asked with `nodoc=1`): the text, `login` and the
/// account served, nothing else.
Map<String, Object?> _leanMessage(String message, {required bool login, required int uid}) => {
  'ok': 0,
  'error': 'message',
  'api': 1,
  'message': message,
  'login': login ? 1 : 0,
  'uid': uid,
  'checknewpm': '',
};

/// The message of a guest asked to log in.
const _loginBlocks = '<div id="messagelogin"></div><div id="messagetext" class="alert_info"><p>您需要先登录才能继续本操作</p></div>';

/// How the fake forum answers a request.
sealed class _Reply {
  const _Reply();
}

/// The web page.
final class _Html extends _Reply {
  const _Html(this.body);
  final String body;
}

/// A body served as `application/json`; the empty one is read as null.
final class _Json extends _Reply {
  const _Json(this.body);
  final String body;
}

/// The request never reaches the forum.
final class _NetworkError extends _Reply {
  const _NetworkError();
}

_Json _jsonOf(Map<String, Object?> answer) => _Json(jsonEncode(answer));

/// Answers every request with [reply] but the app API's own actions (`id=tsdmapp:api`), which are the plugin's "not
/// found" page: a title shop or a medal centre asks them first and goes on to the page.
final class _Forum implements HttpClientAdapter {
  _Forum(this.reply);

  final _Reply reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.queryParameters['id'] == 'tsdmapp:api') {
      return ResponseBody.fromString(
        '<html><body>plugin not found</body></html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    return switch (reply) {
      _NetworkError() => throw DioException.connectionError(requestOptions: options, reason: 'unreachable'),
      _Html(:final body) => ResponseBody.fromString(
        body,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      ),
      _Json(:final body) => ResponseBody.fromString(
        body,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      ),
    };
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _clientOf(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

/// The page the way the tests compare it: the forum message, the login prompt, the account served and the rows.
String _docView(uh.Document d) => [
  d.querySelector('#messagetext')?.text?.trim() ?? '-',
  d.querySelector('#messagelogin') != null,
  parseLoggedUidFromDocument(d),
  d.querySelectorAll('li').length,
].join('|');

/// The forum page the way the tests compare it: the forum message, the login prompt, the poll offer and the rows.
String _forumView(ForumPageData page) => [
  page.permissionDeniedMessage?.text?.trim() ?? '-',
  page.needLogin,
  page.pollOfferUid,
  page.normalThreadList.length + page.stickThreadList.length,
].join('|');

/// [task] as a state: `failure` for any failure the request or the answer gave, `message` for the forum's own refusal
/// (the search shows it as it is), else [view] of what it gave.
Future<String> _state<T>(AsyncEither<T> task, String Function(T value) view) async => switch (await task.run()) {
  Left(value: ServerRespondedErrorException(:final message)) => 'message:$message',
  Left() => 'failure',
  Right(:final value) => 'ok:${view(value)}',
};

/// [read] as a state, for the callers that throw their failure.
Future<String> _thrown(Future<String> Function() read) async {
  try {
    return await read();
  } on AppException {
    return 'failure';
  }
}

/// One caller of the JSON mode: `run` leaves the page of the caller in a state, as a comparable text (`failure`, or what
/// the caller parsed from the answer).
typedef _Caller = ({
  String name,
  Future<String> Function(NetClientProvider client) run,
  // Whether the page of the caller is built from an ordinary answer by the harness (false: only the failures apply).
  bool pages,
});

/// Every caller of the JSON mode, each given the client of the forum under test. The ones that look up the app's
/// default client are served through [getIt] by [_stateOf].
final List<_Caller> _callers = [
  (
    name: 'forum page',
    run: (_) => _state(
      ForumRepository().fetchForum(fid: '2', filterState: const FilterState()),
      _forumView,
    ),
    pages: true,
  ),
  (name: 'forum group', run: (_) => _state(ForumRepository().fetchForumGroup('1'), (v) => '$v'), pages: true),
  (name: 'homepage', run: (_) => _homepage(), pages: true),
  (
    name: 'my threads',
    run: (_) => _state(
      MyThreadRepository().fetchDocument('$baseUrl/home.php?mod=space&do=thread&view=me&type=thread'),
      _docView,
    ),
    pages: true,
  ),
  (
    name: 'favorite threads',
    run: (_) => _state(
      FavoriteRepository().fetchListPage(),
      (p) => '${p.items.length}|${p.needLogin}',
    ),
    pages: true,
  ),
  (
    name: 'favorite forums',
    run: (_) => _state(
      FavoriteRepository().fetchForumListPage(),
      (p) => '${p.items.length}|${p.needLogin}',
    ),
    pages: true,
  ),
  (
    name: 'favorites of a type',
    run: (_) => _state(
      FavoriteRepository().fetchListPageOf(FavoriteType.forum),
      (p) => '${p.items.length}|${p.needLogin}',
    ),
    pages: true,
  ),
  (
    name: 'chat history',
    run: (_) => _state(const ChatRepository().fetchChatHistory('1001'), _docView),
    pages: true,
  ),
  (
    name: 'profile of another user',
    run: (_) => _state(
      ProfileRepository().fetchProfile(uid: '1001'),
      (p) => switch (p) {
        ProfileWebPage(:final document) => _docView(document),
        ProfileApiPage(:final json) => _apiMessageView(json),
      },
    ),
    pages: true,
  ),
  (
    name: 'newest threads',
    run: (_) => _state(
      LatestThreadRepository().fetchDocument('$baseUrl/forum.php?mod=guide&view=newthread'),
      _docView,
    ),
    pages: true,
  ),
  (
    name: 'guide index',
    run: (_) => _state(const GuideIndexRepository().fetchGuideIndex(), (v) => '${v.length}'),
    pages: true,
  ),
  (
    name: 'search',
    run: (_) => _state(
      SearchRepository().searchWithParameters(keyword: 'x', fid: '0', uid: '0', pageNumber: 1),
      _docView,
    ),
    pages: true,
  ),
  (
    name: 'friends',
    run: (_) => _state(
      const FriendRepository().fetchPage(FriendRepository.listUrl(uid: '1001')),
      (p) => '${p.items.length}|${p.needLogin}|${p.message}',
    ),
    pages: true,
  ),
  (
    name: 'points statistics',
    run: (_) => _state(PointsRepository().fetchStatisticsPage(), _docView),
    pages: true,
  ),
  (
    name: 'points changelog',
    run: (_) => _state(PointsRepository().fetchChangelogPage(const ChangelogParameter.empty()), _docView),
    pages: true,
  ),
  (
    name: 'my titles',
    run: (_) => _state(MyTitlesRepository().fetchSecondaryTitles(), (v) => '${v.length}'),
    pages: true,
  ),
  (
    name: 'notice detail',
    run: (_) => _state(
      NotificationRepository().fetchDocument('$baseUrl/forum.php?mod=viewthread&tid=123'),
      (v) => _docView(v.$1),
    ),
    pages: true,
  ),
  (
    name: 'thread',
    run: (_) => _state(ThreadRepository().fetchThread(tid: '123'), _docView),
    pages: true,
  ),
  (
    name: 'title shop',
    run: (client) => _thrown(() async {
      try {
        final c = await TitleShopRepository.network(client).fetchPage(titleShopUrl, _uid);
        return 'ok:${c.supported}|${c.items.length}|${c.message}';
      } on TitleShopIdentityException catch (e) {
        return 'identity:${e.guest}';
      }
    }),
    pages: true,
  ),
  (
    name: 'poll card',
    run: (client) => _thrown(() async {
      final poll = await PollRepository.network(
        client,
      ).fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=123&pid=456', _uid);
      return 'ok:${poll.availability}';
    }),
    pages: true,
  ),
  // The ones PR #188 fixed: only the failures apply here (test 205 holds their pages).
  (
    name: 'draft box',
    run: (client) => _thrown(() async {
      await DraftRepository.network(client).load(_uid);
      return 'ok';
    }),
    pages: false,
  ),
  (
    name: 'notification poll',
    run: (client) => _state(NotificationRepository().fetchNotificationWith(client), (_) => ''),
    pages: false,
  ),
];

/// The default client of the app is the forum's too, for the callers that look it up.
void _serve(_Forum forum) => getIt.registerFactory<NetClientProvider>(() => _clientOf(forum));

/// The homepage the way the tests compare it: its document as [_docView]; the structured answer of plugin 2.3.0 (the
/// forum's message among the replies here) as the same four things read from its fields.
String _homeView(ForumHomePage page) => switch (page) {
  ForumHomeWebPage(:final document) => _docView(document),
  ForumHomeApiPage(:final json) => _apiMessageView(json),
};

/// [_docView] of the forum's message answered as fields: the message, the login prompt, the account served, no rows.
String _apiMessageView(Map<String, dynamic> json) => [
  json['message'] ?? '-',
  json['login'] == 1,
  switch (json['uid']) {
    final int uid when uid > 0 => uid,
    _ => null,
  },
  0,
].join('|');

Future<String> _homepage() async {
  final repo = ForumHomeRepository();
  try {
    return await _state(repo.fetchHomePage(force: true), _homeView);
  } finally {
    await repo.dispose();
  }
}

/// The state of [caller] with a forum answering every request with [reply].
Future<String> _stateOf(_Caller caller, _Reply reply) async {
  final forum = _Forum(reply);
  _serve(forum);
  TsdmAppApi.reset();
  return caller.run(_clientOf(forum));
}

/// The answers of the plugin, and the web page it cuts them from, for one kind of page.
typedef _Kind = ({String name, _Reply json, _Reply web});

final List<_Kind> _kinds = [
  (name: 'an empty list', json: _jsonOf(_answer(_emptyBlocks)), web: _Html(_page(_emptyBlocks))),
  (
    name: 'a refused request',
    json: _jsonOf(_answer(_deniedBlocks, ok: false, error: 'message')),
    web: _Html(_page(_deniedBlocks)),
  ),
  (
    name: 'a guest asked to log in',
    json: _jsonOf(_answer(_loginBlocks, ok: false, error: 'message')),
    web: _Html(_page(_loginBlocks)),
  ),
  // Plugin 2.3.0 asked with nodoc=1: the message without its blocks, rebuilt as the page the forum prints.
  (
    name: 'a refused request, lean',
    json: _jsonOf(_leanMessage('抱歉，您没有权限访问该内容', login: false, uid: _uid)),
    web: _Html(_page(_deniedErrorBlocks)),
  ),
  (
    name: 'a guest asked to log in, lean',
    json: _jsonOf(_leanMessage('您需要先登录才能继续本操作', login: true, uid: 0)),
    web: _Html(_guestPage(_loginBlocks)),
  ),
];

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth() {
    _subject.add(const AuthStatusAuthed(UserLoginInfo(username: 'Alice', uid: _uid)));
  }

  final _subject = BehaviorSubject<AuthStatus>();

  @override
  Stream<AuthStatus> get status => _subject.asBroadcastStream();

  @override
  int? get effectiveCurrentUid => _uid;

  Future<void> close() => _subject.close();
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    // Each case serves its own forum to the app's default client.
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('an answer without a page is a failed request, as a network error is', () {
    for (final caller in _callers) {
      test(caller.name, () async {
        expect(await _stateOf(caller, const _NetworkError()), 'failure', reason: 'a network error');
        for (final (label, reply) in [
          // dio reads an empty `application/json` body, and a JSON `null`, as null.
          ('an empty body', const _Json('')),
          ('a null body', const _Json('null')),
          // An empty body served as a web page is an empty string to dio (a PHP fatal error with the errors hidden).
          ('an empty web page', const _Html('')),
          ('a blank web page', const _Html(' \n')),
          ('a failed build', _jsonOf({'ok': 0, 'error': 'internal'})),
        ]) {
          expect(await _stateOf(caller, reply), 'failure', reason: label);
        }
        // A control, not a guard of the fix: a blank body served as JSON is not JSON, dio throws on it and that is a
        // failed request (a transport failure) whatever the app does with an answer.
        expect(await _stateOf(caller, const _Json(' \n')), 'failure', reason: 'a blank JSON body (dio throws)');
      });
    }
  });

  group('a page that has one is parsed as the web page', () {
    for (final caller in _callers.where((e) => e.pages)) {
      test(caller.name, () async {
        for (final kind in _kinds) {
          final fromJson = await _stateOf(caller, kind.json);
          final fromWeb = await _stateOf(caller, kind.web);
          expect(fromJson, isNot('failure'), reason: kind.name);
          expect(fromJson, fromWeb, reason: '${kind.name}: the JSON answer gives what the web page gives');
        }
      });
    }
  });

  group('the profile of the logged user', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
      await settings.setValue<int>(SettingsKeys.loginUid, _uid);
      await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
      TsdmAppApi.reset();
    });

    tearDown(() async {
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await settings.dispose();
      await db.close();
    });

    const profileBlocks =
        '<div id="uhd"><div class="icn avt"><img data-src="data/avatar/000/00/10/00_avatar_middle.jpg" /></div></div>';

    test('an answer without a page is not remembered as the profile, nor read as a logged out page', () async {
      for (final (label, reply) in [
        ('an empty body', const _Json('')),
        ('an empty web page', const _Html('')),
        ('a failed build', _jsonOf({'ok': 0, 'error': 'internal'})),
      ]) {
        _serve(_Forum(reply));
        final repo = ProfileRepository();
        expect(
          (await repo.fetchProfile().run()).getLeft().toNullable(),
          isA<HttpRequestFailedException>(),
          reason: label,
        );
        expect(repo.hasCache(), isFalse, reason: '$label: an empty document is not the profile of the account');
        // The avatar of the homepage asks for the page: a guest page there means the session expired.
        expect(
          (await repo.fetchAvatarUrl(force: true).run()).getLeft().toNullable(),
          isA<HttpRequestFailedException>(),
          reason: '$label: a failed request, not ProfileNeedLoginException',
        );
      }
    });

    test('the page of the forum is remembered, and a guest page is still a logged out page', () async {
      _serve(_Forum(_Html(_page(profileBlocks))));
      final repo = ProfileRepository();
      expect((await repo.fetchProfile().run()).isRight(), isTrue);
      expect(repo.hasCache(), isTrue);
      expect((await repo.fetchAvatarUrl(force: true).run()).getRight().toNullable(), endsWith('00_avatar_middle.jpg'));

      _serve(_Forum(const _Html('<html><body><form id="lsform"></form></body></html>')));
      expect(
        (await repo.fetchAvatarUrl(force: true).run()).getLeft().toNullable(),
        isA<ProfileNeedLoginException>(),
      );
    });
  });

  group('the achievements page and the medal centre', () {
    // A page of the app, not a repository: the fetch it builds for itself is what is asked of the default client.
    Future<void> open(WidgetTester tester, Widget page, _Reply reply) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final auth = _Auth();
      addTearDown(auth.close);
      _serve(_Forum(reply));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: RepositoryProvider<AuthenticationRepository>.value(value: auth, child: page),
            ),
          ),
        );
        // The page loads when it is opened and the dio adapter answers outside the fake clock.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    final pages = <(String, Widget)>[
      ('achievements', const AchievementsPage()),
      ('medal centre', const MedalCenterPage()),
    ];

    for (final (name, page) in pages) {
      testWidgets('$name: a network error and an answer without a page give the failure with its retry', (
        tester,
      ) async {
        for (final (label, reply) in [
          ('a network error', const _NetworkError()),
          ('an empty body', const _Json('')),
          ('an empty web page', const _Html('')),
          ('a failed build', _jsonOf({'ok': 0, 'error': 'internal'})),
        ]) {
          await open(tester, page, reply);
          expect(find.text(t.general.failedToLoad), findsOneWidget, reason: '$name: $label');
          expect(find.text(t.achievementsPage.loginRequired), findsNothing, reason: '$name: $label');
          expect(find.text(t.medalCenter.loginRequired), findsNothing, reason: '$name: $label');
          await tester.pumpWidget(const SizedBox());
        }
      });
    }

    testWidgets('achievements: the page of the forum is not a failure', (tester) async {
      final web = File('test/data/achievements_empty_x5.html').readAsStringSync();
      await open(tester, const AchievementsPage(), _Html(web));
      expect(find.text(t.general.failedToLoad), findsNothing);
      expect(find.text(t.achievementsPage.empty), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
