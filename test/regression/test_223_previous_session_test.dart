/// Background notifications for every logged-in account, the review of the identity fences: a request of a previous
/// session of an account (the same account logged in again with the password meanwhile) and a page that does not
/// follow an account switch.
///
/// * An answer to the previous session, whenever it lands, writes none of its cookies (the jar writes back every
///   cookie of the host it loaded with any `Set-Cookie`, the previous auth cookie included): the global cookie, the
///   cache and the stored row keep the new login, whichever client asked (the app's own, the per-account clients of
///   the sync of all accounts and of auto check-in, the background service's isolate).
/// * Its guest page or `login` answer marks nobody expired: the auto sync, the sync of all accounts, auto check-in
///   and the homepage, which loads again with the new session. Without a new login they still mark as before.
/// * A row read from the database while the account logs in again does not put the previous session back into the
///   cache.
/// * The profile page logs out the account it shows, nobody else; the account in use is logged out also before its
///   stored session was verified, and a failed request is no success.
///
/// Synthetic answers and names, no real account.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/medal_title_tools/view/my_medals_page.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/profile/bloc/profile_bloc.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/dao/dao.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const List<UserLoginInfo> _everyone = [_alice, _bob];

/// The value of the auth cookie of [user]'s stored session; a new login gives `fresh`.
String _token(UserLoginInfo user) => user.username!.toLowerCase();

/// Cookie row in the format the persistent cookie jar reads back: the auth cookie is sent with every request.
Map<String, String> _jar(UserLoginInfo user, [String? token]) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${token ?? _token(user)}; Path=/;_crt=1"}}',
};

final _authRe = RegExp('Ystv_2132_auth=([a-z]+)');

String _tokenOf(RequestOptions options) =>
    _authRe.firstMatch('${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}')?[1] ?? 'no cookie';

String _authedPage(UserLoginInfo user) =>
    '<html><body><div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a> '
    '</strong></div><input type="hidden" name="formhash" value="XXXXXXXX" /></body></html>';

const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form><div id="messagetext"><p>请先登录后才能继续浏览</p></div></body></html>';

/// Every answer renews `lastact`, as Discuz sets it on every request: the jar then writes back the whole host.
Map<String, List<String>> _headers(String type) => {
  Headers.contentTypeHeader: ['$type; charset=utf-8'],
  'set-cookie': ['Ystv_2132_lastact=${DateTime.now().microsecondsSinceEpoch}; Path=/'],
};

ResponseBody _html(String body) => ResponseBody.fromString(body, 200, headers: _headers('text/html'));

ResponseBody _json(Object? body) =>
    ResponseBody.fromString(jsonEncode(body), 200, headers: _headers('application/json'));

/// The structured profile of plugin 2.2.0 as served to [user].
Map<String, dynamic> _profileOf(UserLoginInfo user) {
  final json = jsonDecode(File('test/data/tsdmapp/profile_v4_self.json').readAsStringSync()) as Map<String, dynamic>;
  return {
    ...json,
    'uid': user.uid,
    'user': {...json['user'] as Map<String, dynamic>, 'uid': user.uid, 'username': user.username},
  };
}

/// The structured homepage of plugin 2.3.0 as served to [user].
Map<String, dynamic> _homepageOf(UserLoginInfo user) => {
  ...(jsonDecode(File('test/data/tsdmapp/index_v5_member.json').readAsStringSync()) as Map<String, dynamic>),
  'uid': user.uid,
  'user': {'uid': user.uid, 'username': user.username, 'avatar': 'https://forum.test/data/avatar/noavatar.svg'},
  'red_packet': null,
};

/// The `mymedals` answer of the forum's app API (plugin 1.5.0), as test_198 makes it.
Map<String, dynamic> _myMedals() => {
  'ok': 1,
  'installed': 1,
  'uid': 1000,
  'medals': [
    {'id': 11, 'name': 'Shown medal', 'image': '', 'hidden': 0, 'expiration': 0},
    {'id': 12, 'name': 'Hidden medal', 'image': '', 'hidden': 1, 'expiration': 0},
  ],
  'preview_limit': 30,
  'hide_warning': 'Hiding may lose medals.',
  'log': {'page': 1, 'pages': 1, 'total': 0, 'items': <Object?>[]},
  'hide_form': {
    'url': 'plugin.php?id=dsu_medalCenter:memcp&action=sethide',
    'fields': {'formhash': 'abcd1234', 'dsumcsubmit': '1'},
  },
};

/// The forum of the two accounts and of their new logins: a request is answered for the account of its auth cookie
/// (`fresh` is [freshAs]), as a guest for the tokens in [dead]. While [hold] is pending, requests of [held] wait.
///
/// The switch's check page and the logout's check page (`home.php?mod=spacecp`), the homepage (`forum.php`, the
/// structured answer; the web guest page for a dead session), the profile (the structured answer) and every action of
/// the forum's app API (its `login` answer for a dead session) are answered; anything else fails.
final class _Forum implements HttpClientAdapter {
  _Forum({this.freshAs = _alice});

  final UserLoginInfo freshAs;
  final dead = <String>{};

  /// Actions of the forum's app API answered to a live session, by name.
  final api = <String, Map<String, dynamic>>{};
  final requests = <({String token, String path, String? action})>[];
  String held = 'alice';
  Completer<void>? hold;

  /// The tokens of the requests of the app API action [action] and of the posts, in order.
  List<String> tokensOf(String action) => [
    for (final r in requests)
      if (r.action == action) r.token,
  ];

  /// The tokens of the homepage requests, in order.
  List<String> get homepageTokens => [
    for (final r in requests)
      if (r.path.endsWith('forum.php')) r.token,
  ];

  UserLoginInfo? _userOf(String token) =>
      token == 'fresh' ? freshAs : _everyone.where((u) => _token(u) == token).firstOrNull;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? rs, Future<void>? cancel) async {
    final token = _tokenOf(options);
    final path = options.uri.path;
    requests.add((
      token: token,
      path: path,
      action: options.method == 'POST' ? 'POST' : options.uri.queryParameters['action'],
    ));
    if (hold != null && !hold!.isCompleted && token == held) {
      await hold!.future;
    }
    final user = dead.contains(token) ? null : _userOf(token);
    final query = options.uri.queryParameters;
    if (query['id'] == 'tsdmapp:api') {
      // The plugin's answer for an expired session; an action in [api] is answered to a live one.
      final answer = api[query['action']];
      return _json(user == null || answer == null ? {'ok': 0, 'error': 'login'} : answer);
    }
    if (options.method == 'POST' && query['id'] == 'dsu_medalCenter:memcp' && user != null) {
      return _html('<div id="messagetext" class="alert_right"><p>操作成功</p></div>');
    }
    if (path.endsWith('forum.php')) {
      return user == null ? _html(_guestPage) : _json(_homepageOf(user));
    }
    if (path.endsWith('home.php') && query['mod'] == 'spacecp') {
      return _html(user == null ? _guestPage : _authedPage(user));
    }
    if (path.endsWith('home.php') && query['mod'] == 'space' && user != null) {
      return _json(_profileOf(user));
    }
    throw DioException.connectionError(requestOptions: options, reason: 'unexpected request $path $query');
  }

  @override
  void close({bool force = false}) {}
}

/// The password login of [user]: the login form (GET) gives the session the auth cookie `fresh`, the login (POST)
/// answers success.
final class _PasswordForum implements HttpClientAdapter {
  const _PasswordForum(this.user);

  final UserLoginInfo user;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? rs, Future<void>? cancel) async {
    if (options.method == 'POST') {
      return _html("succeedhandle_login('url', 'ok', {'username':'${user.username}','uid':'${user.uid}'});");
    }
    return ResponseBody.fromString(
      '<div id="layer_login_login"><input name="formhash" value="newhash"></div>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        'set-cookie': ['Ystv_2132_auth=fresh; Path=/'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Holds the result of the next SELECT on the cookie table (already read) until [release] completes.
final class _HoldCookieRead extends QueryInterceptor {
  bool armed = false;
  bool read = false;
  final release = Completer<void>();

  @override
  Future<List<Map<String, Object?>>> runSelect(QueryExecutor executor, String statement, List<Object?> args) async {
    if (armed && statement.contains('cookie')) {
      armed = false;
      final rows = await executor.runSelect(statement, args);
      read = true;
      await release.future;
      return rows;
    }
    return executor.runSelect(statement, args);
  }
}

Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('waited for ${reason ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const _passwordOf = {
  1000: UserCredential(loginField: LoginField.username, loginFieldValue: 'Alice', password: 'p', tsdmVerify: ''),
  1001: UserCredential(loginField: LoginField.username, loginFieldValue: 'Bob', password: 'p', tsdmVerify: ''),
};

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late CookieProvider global;
  late _HoldCookieRead interceptor;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    TsdmAppApi.reset();
    interceptor = _HoldCookieRead();
    db = AppDatabase(NativeDatabase.memory().interceptWith(interceptor));
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    for (final u in _everyone) {
      await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u));
    }
    await settings.setValue(SettingsKeys.loginUid, 1000);
    await settings.setValue(SettingsKeys.loginUsername, 'Alice');
    global = CookieProvider.buildEmpty();
    await global.loadCookieFromStorage(_alice);
    getIt.registerSingleton<CookieProvider>(global);
  });

  tearDown(() async {
    TsdmAppApi.reset();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  String cachedToken(int uid) => _authRe.firstMatch('${storage.getCookieByUidSync(uid)}')?[1] ?? 'none';
  Future<String> storedToken(int uid) async =>
      _authRe.firstMatch((await CookieDao(db).selectCookieByUid(uid))?.cookie ?? '')?[1] ?? 'none';
  String? globalToken() => global.session;
  Future<List<int>> rows() async => (await storage.getAllUsers()).map((e) => e.uid!).toList()..sort();
  Future<Set<int>> expiredUids() async => (await storage.fetchExpiredSessions()).map((e) => e.user.uid!).toSet();

  /// Every client of the app (the default one, bound to the global cookie) asks [forum].
  void appClientsAsk(_Forum forum) => getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  );

  /// The authentication of the app, [user] verified (null: not yet), its password login answered by
  /// [_PasswordForum].
  AuthenticationRepository authWith({UserLoginInfo? user = _alice, UserLoginInfo loginAs = _alice}) {
    final auth = AuthenticationRepository(
      user: user,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _PasswordForum(loginAs),
        cookie: cookie,
      ),
    );
    addTearDown(auth.dispose);
    return auth;
  }

  Future<void> loginWithPassword(AuthenticationRepository auth, UserLoginInfo user) async {
    expect((await auth.loginWithPassword(_passwordOf[user.uid]!).run()).isRight(), isTrue, reason: 'logged in');
  }

  group('a request of the previous session answered after a new login of the same account', () {
    test('writes none of its cookies: the global cookie, the cache and the row keep the new login', () async {
      final forum = _Forum()..hold = Completer<void>();
      appClientsAsk(forum);
      final auth = authWith();
      final pending = getIt.get<NetClientProvider>().get('$baseUrl/forum.php').run();
      await _until(() => forum.requests.isNotEmpty, reason: 'asked with the previous session');
      await loginWithPassword(auth, _alice);
      forum.hold!.complete();
      expect((await pending).getLeft().toNullable(), isA<IdentityChangedException>(), reason: 'dropped');
      expect(globalToken(), 'fresh');
      expect(cachedToken(1000), 'fresh');
      expect(await storedToken(1000), 'fresh');
      expect(cachedToken(1001), 'bob', reason: 'nobody else touched');
    });

    test('a client built before the new login and first used after it sends the new session', () async {
      final forum = _Forum();
      appClientsAsk(forum);
      final auth = authWith();
      // A page keeps the client it was opened with.
      final client = getIt.get<NetClientProvider>();
      await loginWithPassword(auth, _alice);
      expect((await client.get('$baseUrl/forum.php').run()).isRight(), isTrue);
      expect(forum.homepageTokens, ['fresh']);
      expect(await storedToken(1000), 'fresh');
    });

    test(
      'a client kept by a page or a repository goes on with the new session; its request in flight is dropped',
      () async {
        final forum = _Forum()..api['mymedals'] = _myMedals();
        appClientsAsk(forum);
        final auth = authWith();
        // The medal tools pages keep the client they were opened with.
        final client = getIt.get<NetClientProvider>();
        expect((await TsdmAppApi.ask(client, 'mymedals'))?['ok'], 1);
        forum
          ..held = 'alice'
          ..hold = Completer<void>();
        final inFlight = client.get(TsdmAppApi.url('mymedals')).run();
        await _until(() => forum.tokensOf('mymedals').length == 2, reason: 'asked again with the previous session');
        await loginWithPassword(auth, _alice);
        // Asked again after the login, while the previous request is still on its way.
        expect((await TsdmAppApi.ask(client, 'mymedals'))?['ok'], 1, reason: 'answered to the new session');
        final posted = await client
            .postForm(
              '$baseUrl/plugin.php?id=dsu_medalCenter:memcp&action=sethide',
              data: {'formhash': 'abcd1234'},
            )
            .run();
        expect(posted.isRight(), isTrue, reason: '$posted');
        forum.hold!.complete();
        expect(
          (await inFlight).getLeft().toNullable(),
          isA<IdentityChangedException>(),
          reason: 'the previous session',
        );
        expect(forum.tokensOf('mymedals'), ['alice', 'alice', 'fresh']);
        expect(forum.tokensOf('POST'), ['fresh']);
        expect((globalToken(), cachedToken(1000), await storedToken(1000)), ('fresh', 'fresh', 'fresh'));
      },
    );

    test('a client built for the new session works as before, its renewed cookies stored', () async {
      final forum = _Forum();
      appClientsAsk(forum);
      final auth = authWith();
      await loginWithPassword(auth, _alice);
      final page = await getIt.get<NetClientProvider>().get('$baseUrl/forum.php').run();
      expect(page.isRight(), isTrue, reason: '$page');
      expect(forum.homepageTokens, ['fresh']);
      expect(await storedToken(1000), 'fresh');
      expect((await CookieDao(db).selectCookieByUid(1000))!.cookie, contains('lastact'), reason: 'renewed and stored');
    });

    test('the homepage loads again with the new session: shown, nobody marked expired', () async {
      final forum = _Forum()
        ..dead.add('alice')
        ..hold = Completer<void>();
      appClientsAsk(forum);
      final auth = authWith();
      final forumHome = ForumHomeRepository();
      addTearDown(forumHome.dispose);
      final bloc = HomepageBloc(
        forumHomeRepository: forumHome,
        profileRepository: ProfileRepository(),
        authenticationRepository: auth,
      );
      addTearDown(bloc.close);
      bloc.add(HomepageRefreshRequested());
      await _until(() => forum.homepageTokens.isNotEmpty, reason: 'the homepage asked with the dead session');
      await loginWithPassword(auth, _alice);
      expect(await expiredUids(), isEmpty);
      forum.hold!.complete();
      await _until(() => bloc.state.status == HomepageStatus.success, reason: 'the homepage of the new session');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(forum.homepageTokens, ['alice', 'fresh'], reason: 'the dropped page, then one load with the new session');
      expect(bloc.state.status, HomepageStatus.success);
      expect(await expiredUids(), isEmpty, reason: 'the guest page of the previous session marks nothing');
      expect((globalToken(), await storedToken(1000)), ('fresh', 'fresh'));
      expect(auth.currentUser?.uid, 1000);
    });

    test('control: the dead session without a new login still marks the account expired on the homepage', () async {
      final forum = _Forum()..dead.add('alice');
      appClientsAsk(forum);
      final auth = authWith(user: null);
      final forumHome = ForumHomeRepository();
      addTearDown(forumHome.dispose);
      final bloc = HomepageBloc(
        forumHomeRepository: forumHome,
        profileRepository: ProfileRepository(),
        authenticationRepository: auth,
      );
      addTearDown(bloc.close);
      bloc.add(HomepageRefreshRequested());
      await _until(() => bloc.state.status == HomepageStatus.needLogin, reason: 'the guest page');
      await _until(() => forum.homepageTokens.isNotEmpty);
      expect(await expiredUids(), {1000});
    });

    test("the sync of all accounts (each account's own cookie) writes nothing over it and marks nothing", () async {
      await storage.markSessionExpired(1000);
      final forum = _Forum()..hold = Completer<void>();
      final sync = NotificationSyncAllRepository(
        storageProvider: storage,
        notificationRepository: NotificationRepository(storageProvider: storage),
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: cookie,
        ),
        gap: Duration.zero,
      );
      addTearDown(sync.dispose);
      final auth = authWith();
      final syncing = sync.syncAll(accounts: [_alice]).run();
      await _until(() => forum.requests.isNotEmpty, reason: "Alice's notify asked with her previous session");
      await loginWithPassword(auth, _alice);
      expect(await expiredUids(), isEmpty, reason: 'the login cleared the mark');
      forum.hold!.complete();
      final finished = (await syncing).getOrElse((_) => throw StateError('the sync failed')).finished;
      expect(finished.single.$2, isA<NotificationSyncResultNotAuthorized>(), reason: 'answered "login"');
      expect(await expiredUids(), isEmpty, reason: 'the fresh login is not marked expired by the late answer');
      expect((cachedToken(1000), await storedToken(1000)), ('fresh', 'fresh'), reason: 'its lastact not written back');
    });

    test("auto check-in (each account's own cookie) marks nothing either", () async {
      final forum = _Forum()..hold = Completer<void>();
      final checkin = AutoCheckinRepository(
        storageProvider: storage,
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: cookie,
        ),
        gap: Duration.zero,
        retryDelays: const [],
      );
      addTearDown(checkin.dispose);
      final auth = authWith();
      final running = checkin
          .checkinAll(waitingList: [_alice], skippedList: const [], feeling: CheckinFeeling.happy, message: 'hi')
          .run();
      await _until(() => forum.requests.isNotEmpty, reason: "Alice's check-in asked with her previous session");
      await loginWithPassword(auth, _alice);
      forum.hold!.complete();
      await running;
      expect(await expiredUids(), isEmpty);
      expect((cachedToken(1000), await storedToken(1000)), ('fresh', 'fresh'));
    });

    test('the auto sync of the account in use (the default client) marks nothing', () async {
      await storage.markSessionExpired(1000);
      final forum = _Forum()..hold = Completer<void>();
      appClientsAsk(forum);
      final auth = authWith();
      final notifications = NotificationRepository(storageProvider: storage);
      addTearDown(notifications.dispose);
      final polling = notifications.fetchNotificationV2(uid: 1000, timestamp: 0).run();
      await _until(() => forum.requests.isNotEmpty, reason: 'notify asked with the previous session');
      await loginWithPassword(auth, _alice);
      expect(await expiredUids(), isEmpty, reason: 'the login cleared the mark');
      forum.hold!.complete();
      await polling;
      expect(forum.tokensOf('notify'), ['alice'], reason: 'its answer dropped');
      expect(forum.requests.skip(1).map((r) => r.token), everyElement('fresh'), reason: 'the rest of the fetch');
      expect(await expiredUids(), isEmpty, reason: 'the fresh login is not marked expired by the late answer');
      expect((globalToken(), await storedToken(1000)), ('fresh', 'fresh'));
    });

    test('control: without a new login the "login" answers still mark, each client its own account', () async {
      final forum = _Forum();
      appClientsAsk(forum);
      final notifications = NotificationRepository(storageProvider: storage);
      addTearDown(notifications.dispose);
      expect((await notifications.fetchNotificationV2(uid: 1000, timestamp: 0).run()).isLeft(), isTrue);
      expect(await expiredUids(), {1000}, reason: 'the auto sync of the account in use');

      final sync = NotificationSyncAllRepository(
        storageProvider: storage,
        notificationRepository: notifications,
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: cookie,
        ),
        gap: Duration.zero,
      );
      addTearDown(sync.dispose);
      await sync.syncAll(accounts: [_bob]).run();
      expect(await expiredUids(), {1000, 1001}, reason: 'the sync of all accounts');
      expect(await storedToken(1001), 'bob');
      expect((await CookieDao(db).selectCookieByUid(1001))!.cookie, contains('lastact'), reason: 'renewed and stored');

      await storage.clearSessionExpired(1001);
      final checkin = AutoCheckinRepository(
        storageProvider: storage,
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: cookie,
        ),
        gap: Duration.zero,
        retryDelays: const [],
      );
      addTearDown(checkin.dispose);
      await checkin
          .checkinAll(waitingList: [_bob], skippedList: const [], feeling: CheckinFeeling.happy, message: 'hi')
          .run();
      expect(await expiredUids(), {1000, 1001}, reason: 'auto check-in');
    });

    test("the background service's isolate: its write and its mark of the previous session are refused", () async {
      // The service opens the same database from its own isolate, with its own cache.
      final service = StorageProvider(db, {}, {});
      await service.refreshCookieCache();
      final loaded = Map<String, String>.from(service.getCookieByUidSync(1000)!);
      final previous = cookieSessionOf(loaded);
      expect(previous, 'alice');
      // The app: Alice logs in again with her password.
      await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _jar(_alice, 'fresh'));
      // The service: its fetch with her previous session comes back renewed, then as "login".
      final renewed = {...loaded, baseHost: loaded[baseHost]!.replaceFirst('}}', ',"Ystv_2132_lastact":"x"}}')};
      expect(
        await service.saveCookieOfSession(username: 'Alice', uid: 1000, cookie: renewed, session: previous),
        isFalse,
      );
      await service.markSessionExpiredIfHeld(1000, session: previous);
      expect(await storedToken(1000), 'fresh');
      expect(await expiredUids(), isEmpty);
      // The session the row holds is still renewed and marked as before.
      final bob = Map<String, String>.from(service.getCookieByUidSync(1001)!);
      expect(
        await service.saveCookieOfSession(username: 'Bob', uid: 1001, cookie: bob, session: cookieSessionOf(bob)),
        isTrue,
      );
      await service.markSessionExpiredIfHeld(1001, session: 'bob');
      expect(await expiredUids(), {1001});
    });
  });

  test('a row read from the database while its account logs in again does not put the previous session back', () async {
    final switchForum = _Forum(freshAs: _bob)..dead.add('bob');
    var switching = false;
    final auth = AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))
          ..httpClientAdapter = switching ? switchForum : const _PasswordForum(_bob),
        cookie: cookie,
      ),
    );
    addTearDown(auth.dispose);
    // The in-app round of the other accounts reads Bob's cookie from the database (his previous, dead session)...
    interceptor.armed = true;
    final sync = CookieProvider.buildEmpty();
    final loading = sync.loadCookieFromDatabase(_bob);
    await _until(() => interceptor.read, reason: 'the row read');
    // ...while Bob logs in again with his password.
    await loginWithPassword(auth, _bob);
    expect(cachedToken(1001), 'fresh');
    interceptor.release.complete();
    expect(await loading, isTrue);
    expect(cachedToken(1001), 'fresh', reason: 'the row read before the login stays out of the cache');
    expect(sync.session, 'fresh', reason: 'the sync polls with his new login');
    // Back to Alice, then to Bob: his new login.
    switching = true;
    expect((await auth.switchUser(_alice).run()).isRight(), isTrue);
    expect((await auth.switchUser(_bob).run()).isRight(), isTrue, reason: 'switched with his new login');
    expect(await expiredUids(), isEmpty);
    expect(auth.currentUser?.uid, 1001);
  });

  testWidgets('a page kept open while its account logs in again (my medals) goes on with the new login', (
    tester,
  ) async {
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    final forum = _Forum()..api['mymedals'] = _myMedals();
    appClientsAsk(forum);
    final auth = authWith();
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: MyMedalsPage())));
    await settle();
    expect(find.text('1 shown, 1 hidden'), findsOneWidget);
    expect(forum.tokensOf('mymedals'), ['alice']);

    // Its login expired: logged in again from the banner, back on the page, pulled to refresh.
    await tester.runAsync(() => loginWithPassword(auth, _alice));
    forum.api['mymedals'] = {
      ..._myMedals(),
      'medals': [
        {'id': 11, 'name': 'Shown medal', 'image': '', 'hidden': 0, 'expiration': 0},
        {'id': 12, 'name': 'Hidden medal', 'image': '', 'hidden': 0, 'expiration': 0},
      ],
    };
    unawaited(tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show());
    await settle();
    expect(forum.tokensOf('mymedals'), ['alice', 'fresh'], reason: 'asked with the new login');
    expect(find.text('2 shown, 0 hidden'), findsOneWidget, reason: 'its answer shown, no failure');
    expect(await tester.runAsync(() => storedToken(1000)), 'fresh');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  group('logout', () {
    /// The own profile page as Alice, loaded.
    Future<ProfileBloc> profileOfAlice(AuthenticationRepository auth) async {
      final profile = ProfileBloc(profileRepository: ProfileRepository(), authenticationRepository: auth)
        ..add(const ProfileLoadRequested(username: null, uid: null));
      addTearDown(profile.close);
      await _until(() => profile.state.status == ProfileStatus.success, reason: "Alice's profile");
      expect(profile.state.userProfile?.uid, '1000');
      return profile;
    }

    test('the profile page logs out the account it shows: switched meanwhile, nobody; then the one in use', () async {
      appClientsAsk(_Forum());
      final switchForum = _Forum()..held = 'bob';
      final loggedOutAs = <int?>[];
      final auth = AuthenticationRepository(
        user: _alice,
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = switchForum,
          cookie: cookie,
        ),
        currentUserClientFactory: (u) {
          loggedOutAs.add(u.uid);
          // The forum answers the guest page: the logout drops the saved login.
          return NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Forum());
        },
      );
      addTearDown(auth.dispose);
      final profile = await profileOfAlice(auth);

      // A tap on Bob's notification switches while the user confirms the logout on Alice's profile page.
      switchForum.hold = Completer<void>();
      final switching = auth.switchUser(_bob).run();
      await _until(() => switchForum.requests.isNotEmpty, reason: "the check of Bob's login");
      profile.add(ProfileLogoutRequested());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      switchForum.hold!.complete();
      expect((await switching).isRight(), isTrue);
      await _until(
        () => profile.state.status == ProfileStatus.success && profile.state.userProfile?.uid == '1001',
        reason: 'the page shows the account in use',
      );
      expect(loggedOutAs, isEmpty, reason: 'nobody logged out');
      expect(await rows(), [1000, 1001]);

      // Switched back to Alice from elsewhere (the page does not follow), then the logout asked on Bob's page.
      expect((await auth.switchUser(_alice).run()).isRight(), isTrue);
      expect(profile.state.userProfile?.uid, '1001', reason: 'the page did not follow');
      profile.add(ProfileLogoutRequested());
      await _until(
        () => profile.state.status == ProfileStatus.success && profile.state.userProfile?.uid == '1000',
        reason: 'the page shows the account in use',
      );
      expect(loggedOutAs, isEmpty, reason: 'Alice, in use, was not the account the page showed');
      expect(await rows(), [1000, 1001]);
      expect(auth.currentUser?.uid, 1000);

      // The page shows the account in use: logged out.
      profile.add(ProfileLogoutRequested());
      await _until(() => profile.state.status == ProfileStatus.needLogin, reason: 'logged out');
      expect(loggedOutAs, [1000]);
      expect(await rows(), [1001]);
    });

    test('the account in use before its session is verified is logged out for real', () async {
      final asked = <int?>[];
      final auth = AuthenticationRepository(
        currentUserClientFactory: (u) {
          asked.add(u.uid);
          // Her session is gone on the forum: the guest page.
          return NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Forum());
        },
      );
      addTearDown(auth.dispose);
      expect(auth.currentUser, isNull, reason: 'an offline start: never verified');
      expect(auth.effectiveCurrentUid, 1000, reason: 'the manage accounts page shows her online');
      expect((await auth.logout(uid: 1000).run()).isRight(), isTrue);
      expect(asked, [1000], reason: 'the forum was asked');
      expect(await rows(), [1001], reason: 'her saved login removed');
      expect(auth.effectiveCurrentUid, isNull);
    });

    test('a logout queued behind the homepage verifying the session runs after it', () async {
      final asked = <int?>[];
      final auth = AuthenticationRepository(
        currentUserClientFactory: (u) {
          asked.add(u.uid);
          return NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Forum());
        },
      );
      addTearDown(auth.dispose);
      final record = auth.loginWithServedUser(_alice, guest: false, fetchedAs: 1000).run();
      // Asked for the account in use (not verified yet when asked, verified by the time it runs).
      expect(auth.currentUser, isNull);
      final logout = auth.logout().run();
      expect((await record).isRight(), isTrue);
      expect((await logout).isRight(), isTrue);
      expect(asked, [1000]);
      expect(await rows(), [1001]);
      expect(auth.currentUser, isNull);
    });

    test('offline: the logout fails instead of a success with nothing done', () async {
      final auth = AuthenticationRepository(
        currentUserClientFactory: (u) => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Offline()),
      );
      addTearDown(auth.dispose);
      expect((await auth.logout(uid: 1000).run()).isLeft(), isTrue);
      expect(await rows(), [1000, 1001], reason: 'nothing removed');
      expect(auth.effectiveCurrentUid, 1000);
    });

    test('another account than the one in use, or none: nothing done, the caller told', () async {
      final asked = <int?>[];
      final auth = AuthenticationRepository(
        currentUserClientFactory: (u) {
          asked.add(u.uid);
          return NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Offline());
        },
      );
      addTearDown(auth.dispose);
      expect((await auth.logout(uid: 1001).run()).getLeft().toNullable(), isA<IdentityChangedException>());
      global.clearUserInfoAndCookie();
      await settings.deleteValue(SettingsKeys.loginUid);
      expect((await auth.logout(uid: 1000).run()).getLeft().toNullable(), isA<IdentityChangedException>());
      expect((await auth.logout().run()).isRight(), isTrue, reason: 'nobody in use, nobody asked for');
      expect(asked, isEmpty);
      expect(await rows(), [1000, 1001]);
    });
  });
}

/// No network.
final class _Offline implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? rs, Future<void>? cancel) async =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}
