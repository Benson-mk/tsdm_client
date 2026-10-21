/// Background notifications for every logged-in account: the Android background message service polls every account
/// saved on this device when `backgroundSyncAllAccounts` is on, the account in use only otherwise, as before.
///
/// * Off (the default): a tick fetches the account in use and nothing else, request for request as before.
/// * On: every account, one after another (the account in use first), each with its own cookie, its own poll slot,
///   its own stored rows and fetch bound, and the plugin's `seen` posted with its own form hash; a pause between two
///   accounts that reached the forum.
/// * A notification carries its account: the payload names the uid, the title names the account and each account
///   gets a notification id of its own. A tap on the notification of another account switches to it (the avatar
///   menu's quick switch) before the notice page opens; nothing opens when the switch does not happen.
/// * An expired login, a failure or a 429 of one account is that account's outcome: the others still run and the
///   account in use is never logged out; another account known to be expired is not polled until it logs in again.
///
/// Synthetic answers and names, no real account.
library;

import 'dart:async';
import 'dart:convert';
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
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/background_sync/background_sync_service.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/background_sync/other_accounts_auto_sync.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/notification/utils/poll_slot.dart';
import 'package:tsdm_client/features/notification/view/notification_sync_all_page.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const _carol = UserLoginInfo(username: 'Carol', uid: 1002);
const List<UserLoginInfo> _everyone = [_alice, _bob, _carol];

/// The value of the auth cookie of [user]; the fake forum tells the accounts apart by it.
String _token(UserLoginInfo user) => user.username!.toLowerCase();

int _uidOf(String token) => _everyone.firstWhere((u) => _token(u) == token).uid!;

/// Cookie row in the format the persistent cookie jar reads back: the auth cookie is sent with every request.
Map<String, String> _jar(UserLoginInfo user) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${_token(user)}; Path=/;_crt=1"}}',
};

/// The forum clock: now, since the repository clamps `since` to three days ago.
final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// The offset (hours) the forum shows the member's times with: the test machine's own zone, see test_211.
final num _offset = DateTime.now().timeZoneOffset.inMinutes / 60;

/// The form hash of account [uid] in its `notify` answer.
String _formhash(int uid) => 'fh$uid';

/// The id of the one unread notice account [uid] has.
int _noticeId(int uid) => uid * 10;

/// A `notify` answer of plugin 1.9.0 for account [uid]: one unread reply notice, two minutes old.
Map<String, Object?> _notifyOf(int uid) => {
  'ok': 1,
  'api': 1,
  'version': '1.9.0',
  'time': _now,
  'uid': uid,
  'formhash': _formhash(uid),
  'timeoffset': _offset,
  'counts': {'notice': 1, 'pm': 0, 'announce': 0},
  'pm_last': 0,
  'notices': [
    {
      'id': _noticeId(uid),
      'new': 1,
      'type': 'post',
      'category': 1,
      'authorid': 3001,
      'author': 'Peer',
      'note':
          '<a href="home.php?mod=space&uid=3001">Peer</a> 回复了您的帖子 '
          '<a href="forum.php?mod=redirect&goto=findpost&ptid=5&pid=$uid" target="_blank">Thread of $uid</a>',
      'text': 'Peer 回复了您的帖子 Thread of $uid',
      'dateline': _now - 120,
      'from_id': 5,
      'from_idtype': 'post',
      'from_num': 0,
    },
  ],
  'pms': <Object?>[],
  'announces': <Object?>[],
};

/// The `pmlist` answer of account [uid] listing [pms].
Map<String, Object?> _pmlistOf(int uid, [List<Map<String, Object?>> pms = const []]) => {
  'ok': 1,
  'api': 1,
  'time': _now,
  'uid': uid,
  'closed': 0,
  'timeoffset': _offset,
  'page': 1,
  'perpage': 20,
  'count': pms.length,
  'pms': pms,
};

/// An unread conversation with peer 3001 (the author of every notice here) for account [uid], one minute old.
Map<String, Object?> _conversationOf(int uid) => {
  'plid': uid,
  'new': 1,
  'type': 1,
  'subject': '',
  'count': 2,
  'members': 2,
  'touid': 3001,
  'tousername': 'Peer',
  'lastauthorid': 3001,
  'lastauthor': 'Peer',
  'lastsummary': 'hello $uid',
  'lastsummary_html': 'hello $uid',
  'lastdateline': _now - 60,
};

const _emptyBroadcastPage = '<html><body><div id="um"></div><div class="pml"></div></body></html>';

/// One answer of the fake forum.
final class _Answer {
  const _Answer(this.body, {this.status = 200, this.type = 'text/html'});

  _Answer.json(Object? json, {int status = 200}) : this(jsonEncode(json), status: status, type: 'application/json');

  final String body;
  final int status;
  final String type;
}

/// The plugin's answer to a cookie whose session is dead: every plugin version answers it before the action.
final _loginAnswer = _Answer.json({'ok': 0, 'error': 'login'});

/// HTTP 429 without `Retry-After`: the account is rate limited this time.
final _busy = _Answer.json({'ok': 0, 'error': 'busy'}, status: 429);

/// A server error.
const _serverError = _Answer('<html><body>Server Error</body></html>', status: 500);

/// One request the forum received: the account (the token of its auth cookie) and what was asked.
typedef _Request = ({String token, String name, DateTime at});

/// The forum of three accounts, told apart by the auth cookie each request carries.
///
/// Every account answers as plugin 1.9.0 with one unread notice unless [all] says otherwise for it; [holds] keeps the
/// `notify` of an account unanswered until completed.
final class _Forum implements HttpClientAdapter {
  /// Every request of an account (by token) answered with this.
  final all = <String, _Answer>{};

  /// The `notify` of an account (by token) answered only once this completes.
  final holds = <String, Completer<void>>{};

  /// The conversations `pmlist` lists for an account (by token), none when missing.
  final pms = <String, List<Map<String, Object?>>>{};

  final requests = <_Request>[];
  final seenForms = <({String token, Map<String, String> form})>[];
  final unexpected = <String>[];

  /// What [token] asked, in order.
  List<String> of(String token) => requests.where((r) => r.token == token).map((r) => r.name).toList();

  /// The accounts in the order their requests came.
  List<String> get tokens => requests.map((r) => r.token).toList();

  static final _authRe = RegExp('Ystv_2132_auth=([a-z]+)');

  static String _name(RequestOptions r) {
    final q = r.uri.queryParameters;
    if (q['id'] == 'tsdmapp:api') {
      return q['action'] ?? '?';
    }
    if (q['do'] == 'notice') {
      return 'notice page';
    }
    return switch (q['filter']) {
      'privatepm' => 'pm page',
      'announcepm' => 'broadcast page',
      _ => '${r.method} ${r.uri}',
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final cookie = '${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}';
    final token = _authRe.firstMatch(cookie)?[1] ?? 'no cookie';
    final name = _name(options);
    requests.add((token: token, name: name, at: DateTime.now()));
    if (requestStream != null) {
      final body = utf8.decode(await requestStream.expand((e) => e).toList());
      if (name == 'seen') {
        seenForms.add((token: token, form: Uri.splitQueryString(body)));
      }
    }
    if (name == 'notify' && holds[token] != null) {
      await holds[token]!.future;
    }
    final uid = _everyone.any((u) => _token(u) == token) ? _uidOf(token) : null;
    final answer =
        all[token] ??
        switch (name) {
          'notify' when uid != null => _Answer.json(_notifyOf(uid)),
          'pmlist' when uid != null => _Answer.json(_pmlistOf(uid, pms[token] ?? const [])),
          'seen' when uid != null => _Answer.json({
            'ok': 1,
            'api': 1,
            'time': _now,
            'uid': uid,
            'notice': 1,
            'newer': 0,
            'pm': 1,
          }),
          'broadcast page' => const _Answer(_emptyBroadcastPage),
          _ => null,
        };
    if (answer == null) {
      unexpected.add('$token ${options.method} ${options.uri}');
      throw DioException.connectionError(requestOptions: options, reason: 'unexpected request');
    }
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: ['${answer.type}; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Ticks one interval apart: the poll slots never skip them.
var _ticks = 0;
DateTime _nextTick() => DateTime(2026, 10, 21).add(Duration(minutes: 5 * _ticks++));

/// What a notice page shows the account in use as, and the order things happened in around a notification tap.
final _log = <String>[];

/// The notification bloc of the app, reduced to recording the reload asked after the switch.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this._auth);

  final AuthenticationRepository _auth;

  @override
  void add(NotificationEvent event) => _log.add('${event.runtimeType} as ${_auth.currentUser?.uid}');

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// The check page the switch reads, as served to a logged-in [user].
String _authedPage(UserLoginInfo user) =>
    '<html><body><div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a> '
    '</strong></div><input type="hidden" name="formhash" value="XXXXXXXX" /></body></html>';

const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form><div id="messagetext"><p>请先登录后才能继续浏览</p></div></body></html>';

/// The forum the switch checks the stored login with: the account named by the auth cookie of the request, or the
/// guest page for the tokens in [expired].
final class _SwitchForum implements HttpClientAdapter {
  final expired = <String>{};
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final cookie = '${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}';
    final token = _Forum._authRe.firstMatch(cookie)?[1] ?? 'no cookie';
    requests.add(token);
    final user = _everyone.where((u) => _token(u) == token).firstOrNull;
    return ResponseBody.fromString(
      user == null || expired.contains(token) ? _guestPage : _authedPage(user),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _Forum forum;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    forum = _Forum();
    _log.clear();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });

  tearDown(() async {
    TsdmAppApi.reset();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  NotificationSyncAllRepository repository() {
    final repo = NotificationSyncAllRepository(
      storageProvider: storage,
      notificationRepository: NotificationRepository(storageProvider: storage),
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
        cookie: cookie,
      ),
      // One account per call, as in the service: the tick spaces the accounts.
      gap: Duration.zero,
    );
    addTearDown(repo.dispose);
    return repo;
  }

  /// Alice (in use), Bob and Carol are logged in on this device; the service is on, auto sync every minute.
  Future<void> loggedIn({required bool allAccounts}) async {
    for (final u in _everyone) {
      await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u));
    }
    await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
    await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
    await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
    await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, allAccounts);
  }

  Future<List<BackgroundSyncOutcome>> tick({
    DateTime? now,
    Duration gap = Duration.zero,
    Duration deadline = backgroundSyncDeadline,
    void Function(BackgroundSyncOutcome late)? onLate,
    List<BackgroundSyncOutcome>? announced,
  }) => backgroundSyncAccountsTick(
    storage: storage,
    repository: repository(),
    now: now ?? _nextTick(),
    gap: gap,
    deadline: deadline,
    onLate: onLate,
    onOutcome: announced?.add,
  );

  /// The one request shape of a first fetch with plugin 1.9.0: `notify`, then the conversation list and the broadcast
  /// page side by side, then `seen` for the unread notice and the private message prompt.
  void expectOneFetch(List<String> names, {required String reason}) {
    expect(names, hasLength(4), reason: reason);
    expect(names.first, 'notify', reason: reason);
    expect(names.sublist(1, 3), unorderedEquals(['pmlist', 'broadcast page']), reason: reason);
    expect(names.last, 'seen', reason: reason);
  }

  Future<List<int>> storedNotices(int uid) async =>
      (await storage.fetchNotificationSince(uid: uid, timestamp: 0).run()).noticeList.map((e) => e.nid).toList();

  Future<DateTime?> boundOf(int uid) async =>
      (await storage.fetchLastFetchNoticeTime(uid).run()).getOrElse((_) => null);

  Future<Set<int>> expiredUids() async => (await storage.fetchExpiredSessions()).map((e) => e.user.uid!).toSet();

  group('the setting', () {
    test('off by default; read fresh from the database by the service', () async {
      expect(SettingsKeys.backgroundSyncAllAccounts.defaultValue, isFalse);
      expect(settings.currentSettings.backgroundSyncAllAccounts, isFalse);
      expect((await readBackgroundSyncSettings(storage)).allAccounts, isFalse);

      // Written by the app's settings page, read by the service isolate through its own provider.
      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, true);
      final service = StorageProvider(db, {}, {});
      expect((await readBackgroundSyncSettings(service)).allAccounts, isTrue);
      final reread = SettingsRepository(storage);
      addTearDown(reread.dispose);
      await reread.init();
      expect(reread.currentSettings.backgroundSyncAllAccounts, isTrue);
    });

    test('named in all three languages', () async {
      final tw = await AppLocale.zhTw.build();
      final cn = await AppLocale.zhCn.build();
      final en = await AppLocale.en.build();
      expect(tw.settingsPage.behaviorSection.backgroundSyncAllAccounts.title, '背景通知：所有已登入帳號');
      expect(cn.settingsPage.behaviorSection.backgroundSyncAllAccounts.title, '后台通知：所有已登录账号');
      expect(en.settingsPage.behaviorSection.backgroundSyncAllAccounts.title, contains('all logged-in accounts'));
      expect(tw.settingsPage.behaviorSection.backgroundSyncAllAccounts.seenNote, contains('已讀'));
      expect(en.settingsPage.behaviorSection.backgroundSyncAllAccounts.seenNote, contains('read on the website'));
      for (final tr in [tw, cn, en]) {
        expect(tr.settingsPage.behaviorSection.backgroundSyncAllAccounts.detail, isNotEmpty);
        expect(tr.settingsPage.behaviorSection.backgroundSyncAllAccounts.seenNote, isNotEmpty);
        expect(tr.noticePage.syncAllPage.user.recent(unreadNotice: 1, unreadPm: 2, unreadBm: 3), contains('1/2/3'));
        expect(tr.localNotification.accountGone, isNotEmpty);
        expect(tr.localNotification.notice.titleOf(username: 'Bob'), contains('Bob'));
      }
    });
  });

  group('off: the account in use only, as before', () {
    test('one fetch of Alice, request for request; Bob and Carol are not touched', () async {
      await loggedIn(allAccounts: false);
      final announced = <BackgroundSyncOutcome>[];
      final at = _nextTick();
      final outcomes = await tick(now: at, announced: announced);

      expect(outcomes, hasLength(1));
      expect(announced, outcomes, reason: 'handed over as soon as it is done');
      final done = outcomes.single as BackgroundSyncDone;
      expect(done.uid, _alice.uid);
      expect(done.named, isFalse, reason: 'the notification looks as before');
      expect(done.result, isA<NotificationSyncResultSuccess>().having((e) => e.newNotice, 'newNotice', 1));
      expect(done.latest, isA<NotificationAutoSyncInfoNotice>());

      // The pinned request sequence of the account in use, and nothing else.
      expect(forum.tokens.toSet(), {'alice'});
      expectOneFetch(forum.of('alice'), reason: 'Alice');
      expect(forum.seenForms.map((e) => (e.token, e.form['formhash'])), [('alice', _formhash(1000))]);
      expect(forum.unexpected, isEmpty);

      expect(await storage.getInt(NotificationPollSlot.key(1000)), at.millisecondsSinceEpoch);
      for (final uid in [1001, 1002]) {
        expect(await storage.getInt(NotificationPollSlot.key(uid)), isNull, reason: 'no poll of $uid');
        expect(await storedNotices(uid), isEmpty);
        expect(await boundOf(uid), isNull);
      }
      expect(await storedNotices(1000), [_noticeId(1000)]);
    });

    test('the account switched during the fetch: stored, announced for nobody (as before)', () async {
      await loggedIn(allAccounts: false);
      forum.holds['alice'] = Completer<void>();
      final round = tick();
      while (forum.of('alice').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await settings.setValue(SettingsKeys.loginUid, _bob.uid!);
      forum.holds['alice']!.complete();
      final outcomes = await round;
      expect(
        outcomes.single,
        isA<BackgroundSyncStale>().having((e) => e.reason, 'reason', 'account switched during the fetch'),
      );
      expect(await storedNotices(1000), [_noticeId(1000)]);
      expect(forum.of('bob'), isEmpty);
    });
  });

  group('on: every account', () {
    test('polled one after another, each with its own cookie, slot, rows, bound and form hash', () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      final announced = <BackgroundSyncOutcome>[];
      final outcomes = await tick(now: at, announced: announced);

      expect(forum.unexpected, isEmpty);
      expect(announced, outcomes);
      expect(outcomes.map((e) => (e as BackgroundSyncDone).uid), [1000, 1001, 1002], reason: 'Alice first');
      for (final done in outcomes.cast<BackgroundSyncDone>()) {
        expect(done.named, isTrue);
        expect(done.username, _everyone.firstWhere((u) => u.uid == done.uid).username);
        expect(done.result, isA<NotificationSyncResultSuccess>().having((e) => e.newNotice, 'newNotice', 1));
        expect(done.latest, isA<NotificationAutoSyncInfoNotice>());
      }
      // One account after the other, every request of an account with that account's cookie.
      expect(forum.tokens, [...List.filled(4, 'alice'), ...List.filled(4, 'bob'), ...List.filled(4, 'carol')]);
      for (final u in _everyone) {
        expectOneFetch(forum.of(_token(u)), reason: u.username!);
      }
      // `seen` marks each account's notices read with that account's own form hash and cookie.
      expect(forum.seenForms.map((e) => (e.token, e.form['formhash'], e.form['notice'])), [
        ('alice', _formhash(1000), '$_now'),
        ('bob', _formhash(1001), '$_now'),
        ('carol', _formhash(1002), '$_now'),
      ]);
      for (final u in _everyone) {
        final uid = u.uid!;
        expect(await storedNotices(uid), [_noticeId(uid)], reason: 'rows of $uid are its own');
        expect(await storage.getInt(NotificationPollSlot.key(uid)), at.millisecondsSinceEpoch, reason: 'slot of $uid');
        expect(await boundOf(uid), isNotNull, reason: 'bound of $uid');
      }
      expect(settings.currentSettings.loginUid, 1000, reason: 'nothing switched accounts');
    });

    test("what an account deleted or blocked is its own: keyed by uid, never another account's", () async {
      await loggedIn(allAccounts: true);
      // The same peer wrote to Alice and Bob. Bob deleted the conversation from the app's list (its last message
      // remembered, here one newer than anything fetched); Carol blocked the peer, the author of her notice.
      forum.pms
        ..['alice'] = [_conversationOf(1000)]
        ..['bob'] = [_conversationOf(1001)];
      await storage.saveString('deletedPersonalMessages.1001', '{"3001": {"t": ${_now * 2}, "d": "x"}}');
      final blocks = UserBlockRepository(storage);
      addTearDown(blocks.dispose);
      await blocks.block(ownerUid: 1002, uid: 3001, username: 'Peer');

      final outcomes = (await tick()).cast<BackgroundSyncDone>();
      expect(outcomes.map((e) => e.uid), [1000, 1001, 1002]);
      // Alice: the message wins the announcement.
      expect(outcomes[0].latest, isA<NotificationAutoSyncInfoPm>().having((e) => e.msg, 'msg', 'hello 1000'));
      // Bob: the deleted conversation is neither stored nor news; his notice is.
      expect(outcomes[1].latest, isA<NotificationAutoSyncInfoNotice>());
      // Carol: the notice of the peer she blocked is stored but not announced.
      expect(outcomes[2].latest, isNull);
      expect(outcomes[2].result, isA<NotificationSyncResultSuccess>().having((e) => e.newNotice, 'no news', 0));

      PersonalMessageEntity? conversation(NotificationGroup g) => g.personalMessageList.firstOrNull;
      final alice = await storage.fetchNotificationSince(uid: 1000, timestamp: 0).run();
      final bob = await storage.fetchNotificationSince(uid: 1001, timestamp: 0).run();
      expect(conversation(alice)?.data, 'hello 1000');
      expect(conversation(bob), isNull, reason: "Bob's deletion is Bob's only");
      expect(await storage.getString('deletedPersonalMessages.1001'), isNotNull, reason: 'kept: the copy is older');
      expect(await storage.getString('deletedPersonalMessages.1000'), isNull);
      expect(await storedNotices(1002), [_noticeId(1002)]);
    });

    test('the notification payload carries the uid; title and id name the account', () async {
      await loggedIn(allAccounts: true);
      final tr = await AppLocale.zhTw.build();
      final outcomes = await tick();
      final ids = <int>[];
      for (final done in outcomes.cast<BackgroundSyncDone>()) {
        final content = localNotificationContentOf(
          tr,
          done.latest!,
          account: LocalNoticeAccount(uid: done.uid, username: done.username, named: done.named),
        );
        ids.add(content.id);
        expect(content.title, '[${done.username}] 新訊息');
        expect(content.payload, 'openNotification:${done.uid}');
        expect(LocalNoticeKeys.parseOpenNotification(content.payload), (uid: done.uid));
        expect(isLocalNoticeId(content.id), isTrue);
      }
      expect(ids.toSet(), hasLength(3), reason: 'one notification per account');
      expect(ids, isNot(contains(localNoticeId)));
      expect(ids, isNot(contains(backgroundSyncNotificationId)), reason: 'never the persistent one');

      // Off: the one notification as before, still naming the account in its payload.
      const info = NotificationAutoSyncInfoNotice(
        msg: 'm',
        notice: 1,
        personalMessage: 0,
        broadcastMessage: 0,
        timestamp: 0,
      );
      final single = localNotificationContentOf(tr, info, account: const LocalNoticeAccount(uid: 1000));
      expect((single.id, single.title, single.payload), (localNoticeId, '新訊息', 'openNotification:1000'));
      // The test notification of the settings page names no account.
      final test = localNotificationContentOf(tr, info);
      expect((test.id, test.payload), (localNoticeId, LocalNoticeKeys.openNotification));
    });

    test('an expired account is recorded and skipped; the others run, the account in use stays', () async {
      await loggedIn(allAccounts: true);
      forum.all['bob'] = _loginAnswer;
      final outcomes = await tick();

      expect(outcomes.map((e) => (e as BackgroundSyncDone).uid), [1000, 1001, 1002]);
      final results = outcomes.cast<BackgroundSyncDone>().map((e) => e.result).toList();
      expect(results[0], isA<NotificationSyncResultSuccess>());
      expect(results[1], isA<NotificationSyncResultNotAuthorized>());
      expect(results[2], isA<NotificationSyncResultSuccess>(), reason: 'Carol after the expired Bob');
      expect(outcomes.cast<BackgroundSyncDone>()[1].latest, isNull, reason: 'nothing announced for Bob');
      expect(forum.of('bob'), ['notify'], reason: 'one question, answered "login"');
      expect(await expiredUids(), {1001}, reason: 'recorded for Bob only, as for the account in use');
      expect(
        await storage.getInt(NotificationPollSlot.key(1001)),
        0,
        reason: 'a poll that brought nothing is given back',
      );
      // Alice is still the account in use, her login and rows untouched.
      expect(settings.currentSettings.loginUid, 1000);
      expect(await storage.hasCookieOfUid(1000), isTrue);
      expect(await storage.hasCookieOfUid(1001), isTrue, reason: 'Bob stays saved, to log in again');

      // The next tick does not ask the forum about Bob again until he logs in again.
      forum.requests.clear();
      final next = await tick();
      expect(next.map((e) => (e as BackgroundSyncDone).uid), [1000, 1002]);
      expect(forum.of('bob'), isEmpty);
      await storage.clearSessionExpired(1001);
      forum.all.remove('bob');
      final again = await tick();
      expect(again.map((e) => (e as BackgroundSyncDone).uid), [1000, 1001, 1002]);
    });

    test('the account in use expired: recorded like before, polled again, the others still run', () async {
      await loggedIn(allAccounts: true);
      forum.all['alice'] = _loginAnswer;
      final outcomes = await tick();
      expect(
        outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)),
        [
          (1000, NotificationSyncResultNotAuthorized),
          (1001, NotificationSyncResultSuccess),
          (1002, NotificationSyncResultSuccess),
        ],
      );
      expect(await expiredUids(), {1000});
      expect(settings.currentSettings.loginUid, 1000, reason: 'the service never logs out');
      forum.requests.clear();
      final next = await tick();
      expect(next.map((e) => (e as BackgroundSyncDone).uid), [1000, 1001, 1002], reason: 'as the tick did before');
    });

    test('a server error or a 429 of one account is its own outcome', () async {
      await loggedIn(allAccounts: true);
      forum.all['alice'] = _busy;
      forum.all['bob'] = _serverError;
      final outcomes = await tick();
      expect(
        outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)),
        [
          (1000, NotificationSyncResultRateLimited),
          (1001, NotificationSyncResultFailed),
          (1002, NotificationSyncResultSuccess),
        ],
      );
      expect(await expiredUids(), isEmpty, reason: 'a failure is no expiry');
      expect(await storage.getInt(NotificationPollSlot.key(1000)), 0);
      expect(await storage.getInt(NotificationPollSlot.key(1001)), 0);
      expect(await storedNotices(1002), [_noticeId(1002)]);
    });

    test('a pause between two accounts that reached the forum', () async {
      await loggedIn(allAccounts: true);
      const gap = Duration(milliseconds: 300);
      final outcomes = await tick(gap: gap);
      expect(outcomes, hasLength(3));
      DateTime first(String token) => forum.requests.firstWhere((r) => r.token == token).at;
      DateTime last(String token) => forum.requests.lastWhere((r) => r.token == token).at;
      expect(first('bob').difference(last('alice')), greaterThanOrEqualTo(gap));
      expect(first('carol').difference(last('bob')), greaterThanOrEqualTo(gap));
    });

    test('each account takes its own poll: one polled moments ago is skipped, the others run', () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      // Bob was polled ten seconds ago (half an interval is thirty).
      await storage.saveInt(
        NotificationPollSlot.key(1001),
        at.subtract(const Duration(seconds: 10)).millisecondsSinceEpoch,
      );
      final outcomes = await tick(now: at);
      expect(outcomes[0], isA<BackgroundSyncDone>().having((e) => e.uid, 'uid', 1000));
      expect(
        outcomes[1],
        isA<BackgroundSyncSkipped>()
            .having((e) => e.uid, 'uid', 1001)
            .having((e) => e.reason, 'reason', 'polled by the app moments ago'),
      );
      expect(outcomes[2], isA<BackgroundSyncDone>().having((e) => e.uid, 'uid', 1002));
      expect(forum.of('bob'), isEmpty);

      // A second tick within half an interval polls nobody.
      forum.requests.clear();
      final again = await tick(now: at.add(const Duration(seconds: 20)));
      expect(again.map((e) => (e as BackgroundSyncSkipped).uid), [1000, 1001, 1002]);
      expect(forum.requests, isEmpty, reason: 'the plugin would answer 429 to a second call within its interval');
    });

    test('an account switched during its fetch is announced all the same: the notification opens it', () async {
      await loggedIn(allAccounts: true);
      forum.holds['alice'] = Completer<void>();
      final round = tick();
      while (forum.of('alice').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await settings.setValue(SettingsKeys.loginUid, _carol.uid!);
      forum.holds['alice']!.complete();
      final outcomes = await round;
      expect(outcomes.first, isA<BackgroundSyncDone>().having((e) => (e.uid, e.named), 'Alice, named', (1000, true)));
      expect(outcomes, hasLength(3));
    });

    test('switched off, or back to the account in use only, during the round: it ends there', () async {
      await loggedIn(allAccounts: true);
      forum.holds['bob'] = Completer<void>();
      var round = tick();
      while (forum.of('bob').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, false);
      forum.holds['bob']!.complete();
      var outcomes = await round;
      expect(outcomes[0], isA<BackgroundSyncDone>());
      expect(
        outcomes[1],
        isA<BackgroundSyncStale>().having((e) => e.reason, 'reason', 'all accounts switched off during the fetch'),
      );
      expect(outcomes[2], isA<BackgroundSyncSkipped>());
      expect(outcomes, hasLength(3));
      expect(forum.of('carol'), isEmpty);
      expect(await storedNotices(1001), [_noticeId(1001)], reason: 'what came back is stored all the same');

      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, true);
      forum
        ..requests.clear()
        ..holds['bob'] = Completer<void>();
      round = tick();
      while (forum.of('bob').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, false);
      forum.holds['bob']!.complete();
      outcomes = await round;
      expect(outcomes.last, isA<BackgroundSyncDisabled>(), reason: 'the service stops');
      expect(outcomes, hasLength(2));
      expect(forum.of('carol'), isEmpty);
    });

    test('a fetch given up ends the round; what it brings later is announced for its account', () async {
      await loggedIn(allAccounts: true);
      forum.holds['bob'] = Completer<void>();
      final late = Completer<BackgroundSyncOutcome>();
      final outcomes = await tick(deadline: const Duration(milliseconds: 300), onLate: late.complete);
      expect(outcomes[0], isA<BackgroundSyncDone>().having((e) => e.uid, 'uid', 1000));
      expect(outcomes[1], isA<BackgroundSyncSkipped>().having((e) => e.uid, 'uid', 1001));
      expect(
        outcomes[2],
        isA<BackgroundSyncSkipped>()
            .having((e) => e.uid, 'uid', 1002)
            .having((e) => e.reason, 'reason', 'a fetch before it was given up'),
      );
      expect(forum.of('carol'), isEmpty, reason: 'the network the system holds would hold Carol as long');
      expect(await storage.getInt(NotificationPollSlot.key(1002)), isNull, reason: 'the next tick polls Carol');

      forum.holds['bob']!.complete();
      expect(
        await late.future,
        isA<BackgroundSyncDone>().having((e) => (e.uid, e.named, e.latest != null), 'Bob, announced', (
          1001,
          true,
          true,
        )),
      );
    });

    test('nobody logged in, or auto sync off: nothing polled, as before', () async {
      await loggedIn(allAccounts: true);
      await settings.setValue(SettingsKeys.loginUid, 0);
      expect(
        (await tick()).single,
        isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', 'not logged in'),
      );
      await settings.setValue(SettingsKeys.loginUid, 1000);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 0);
      expect(
        (await tick()).single,
        isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', 'auto sync is off'),
      );
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, false);
      expect((await tick()).single, isA<BackgroundSyncDisabled>());
      expect(forum.requests, isEmpty);
    });
  });

  group('in the app: the other accounts after the account in use (Android, Windows)', () {
    Future<List<BackgroundSyncOutcome>> others({DateTime? now, Duration gap = Duration.zero}) =>
        autoSyncOtherAccountsTick(storage: storage, repository: repository(), now: now ?? _nextTick(), gap: gap);

    test('off: nothing; on: every other account, without the background service switch', () async {
      await loggedIn(allAccounts: false);
      expect(await others(), isEmpty);
      expect(forum.requests, isEmpty);

      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, true);
      // Windows has no background service: its switch is off and plays no part.
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, false);
      final at = _nextTick();
      final outcomes = await others(now: at);
      expect(forum.unexpected, isEmpty);
      expect(
        outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.username, e.named)),
        [
          (1001, 'Bob', true),
          (1002, 'Carol', true),
        ],
        reason: 'the account in use is polled by the in-app sync itself',
      );
      expect(forum.tokens, [...List.filled(4, 'bob'), ...List.filled(4, 'carol')]);
      expect(forum.seenForms.map((e) => (e.token, e.form['formhash'])), [
        ('bob', _formhash(1001)),
        ('carol', _formhash(1002)),
      ]);
      expect(await storage.getInt(NotificationPollSlot.key(1000)), isNull);
      for (final uid in [1001, 1002]) {
        expect(await storage.getInt(NotificationPollSlot.key(uid)), at.millisecondsSinceEpoch);
        expect(await storedNotices(uid), [_noticeId(uid)]);
      }
    });

    test('the slots are shared with the background service: whoever polls first, the other skips', () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      // The background service polled everyone moments ago.
      expect(await tick(now: at), hasLength(3));
      forum.requests.clear();
      final outcomes = await others(now: at.add(const Duration(seconds: 10)));
      expect(
        outcomes.map((e) => (e as BackgroundSyncSkipped).uid),
        [1001, 1002],
      );
      expect(forum.requests, isEmpty, reason: 'never asked twice within the interval');
      // And the other way round.
      final later = at.add(const Duration(minutes: 1));
      expect(await others(now: later), hasLength(2));
      forum.requests.clear();
      final service = await tick(now: later.add(const Duration(seconds: 5)));
      expect(service[0], isA<BackgroundSyncDone>().having((e) => e.uid, 'uid', 1000));
      expect(service.skip(1).map((e) => (e as BackgroundSyncSkipped).uid), [1001, 1002]);
      expect(forum.tokens.toSet(), {'alice'});
    });

    test('an expired, failing or rate-limited account stays with itself; expired ones wait for a login', () async {
      await loggedIn(allAccounts: true);
      forum.all['bob'] = _loginAnswer;
      var outcomes = await others();
      expect(outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)), [
        (1001, NotificationSyncResultNotAuthorized),
        (1002, NotificationSyncResultSuccess),
      ]);
      expect(await expiredUids(), {1001});
      expect(settings.currentSettings.loginUid, 1000, reason: 'nobody logged out');
      forum
        ..requests.clear()
        ..all['carol'] = _busy;
      outcomes = await others();
      expect(outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)), [
        (1002, NotificationSyncResultRateLimited),
      ]);
      expect(forum.of('bob'), isEmpty);
    });

    test('a pause before each account, the first one too: the account in use was just asked', () async {
      await loggedIn(allAccounts: true);
      const gap = Duration(milliseconds: 300);
      final started = DateTime.now();
      expect(await others(gap: gap), hasLength(2));
      DateTime first(String token) => forum.requests.firstWhere((r) => r.token == token).at;
      DateTime last(String token) => forum.requests.lastWhere((r) => r.token == token).at;
      expect(first('bob').difference(started), greaterThanOrEqualTo(gap));
      expect(first('carol').difference(last('bob')), greaterThanOrEqualTo(gap));
    });

    test('switched back to the account in use only during the round: it ends there', () async {
      await loggedIn(allAccounts: true);
      forum.holds['bob'] = Completer<void>();
      final round = others();
      while (forum.of('bob').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, false);
      forum.holds['bob']!.complete();
      final outcomes = await round;
      expect(outcomes, hasLength(2));
      expect(outcomes[0], isA<BackgroundSyncStale>());
      expect(outcomes[1], isA<BackgroundSyncSkipped>());
      expect(forum.of('carol'), isEmpty);
    });

    test('OtherAccountsAutoSync: one round at a time, each account announced with its name and reported', () async {
      await loggedIn(allAccounts: true);
      final announced = <BackgroundSyncDone>[];
      final sync = OtherAccountsAutoSync(
        storage: storage,
        repository: repository(),
        announce: (done) async => announced.add(done),
        gap: Duration.zero,
      );
      final events = <Map<String, dynamic>?>[];
      final sub = sync.synced.listen(events.add);
      addTearDown(sub.cancel);
      forum.holds['bob'] = Completer<void>();
      final round = sync.poll(now: _nextTick());
      while (forum.of('bob').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(sync.isRunning, isTrue);
      expect(await sync.poll(now: _nextTick()), isEmpty, reason: 'skipped while the previous round runs');
      forum.holds['bob']!.complete();
      expect(await round, hasLength(2));
      expect(sync.isRunning, isFalse);
      await pumpEventQueue();

      final tr = await AppLocale.zhTw.build();
      expect(announced.map((e) => e.uid), [1001, 1002]);
      for (final done in announced) {
        final content = localNotificationContentOf(
          tr,
          done.latest!,
          account: LocalNoticeAccount(uid: done.uid, username: done.username, named: done.named),
        );
        expect(content.title, '[${done.username}] 新訊息', reason: 'a Windows toast names the account too');
        expect(LocalNoticeKeys.parseOpenNotification(content.payload), (uid: done.uid));
      }
      expect(events, [
        {'uid': 1001, 'notice': 1, 'personalMessage': 0, 'broadcastMessage': 0},
        {'uid': 1002, 'notice': 1, 'personalMessage': 0, 'broadcastMessage': 0},
      ], reason: 'the shape of the service, for the bridge that reloads the account switched to');
      await sync.dispose();
    });

    test('the auto sync asks for the other accounts after its own poll, and never waits for them', () async {
      await loggedIn(allAccounts: true);
      // The in-app fetch of the account in use goes through the global client, with Alice's cookie.
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: CookieProvider(_alice, _jar(_alice)),
        ),
      );
      final notifications = NotificationRepository(storageProvider: storage);
      addTearDown(notifications.dispose);
      final sync = OtherAccountsAutoSync(
        storage: storage,
        repository: repository(),
        announce: (_) async {},
        gap: Duration.zero,
      );
      late final AutoNotificationCubit auto;
      final calls = <String>[];
      auto = AutoNotificationCubit(
        authenticationRepository: AuthenticationRepository(user: _alice),
        notificationRepository: notifications,
        storageProvider: storage,
        afterPoll: () {
          calls.add('after the poll, pending=${auto.isPending}');
          unawaited(sync.poll());
        },
      );
      addTearDown(() async {
        auto.stop();
        await auto.close();
      });
      forum
        ..holds['alice'] = Completer<void>()
        ..holds['bob'] = Completer<void>();
      auto.start(const Duration(seconds: 1));
      while (forum.of('alice').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(auto.isPending, isTrue);
      expect(calls, isEmpty, reason: 'the account in use first');
      forum.holds['alice']!.complete();
      while (forum.of('bob').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(calls, ['after the poll, pending=false']);
      expect(forum.tokens.first, 'alice');
      // An account switch pauses the auto sync: with the other accounts still being polled it gets it at once.
      expect(auto.pause('switch user'), isFalse, reason: 'not pending');
      auto.stop();
      forum.holds['bob']!.complete();
      while (sync.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(forum.tokens.toSet(), {'alice', 'bob', 'carol'});
      expect(await storedNotices(1001), [_noticeId(1001)]);
      await sync.dispose();
    });
  });

  group('the sync of all accounts the user asks for', () {
    test("takes each account's poll: one polled moments ago shows what is stored, nobody is asked twice", () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      // The background service polled Bob ten seconds ago and stored his notice.
      final service = await tick(now: at.subtract(const Duration(seconds: 10)));
      expect(service, hasLength(3));
      await storage.saveInt(NotificationPollSlot.key(1000), 0);
      await storage.saveInt(NotificationPollSlot.key(1002), 0);
      forum.requests.clear();

      final run = await repository()
          .syncAll(accounts: _everyone, pollInterval: const Duration(seconds: 60), now: at)
          .run();
      final results = run.getOrElse((e) => fail('$e')).finished;
      expect(results.map((e) => e.$1.uid), [1000, 1001, 1002]);
      expect(
        results[1].$2,
        isA<NotificationSyncResultSuccess>().having((e) => e.recent, 'recent', isTrue).having(
          (e) => (e.newNotice, e.unreadNotice),
          'nothing new, the stored unread notice',
          (0, 1),
        ),
      );
      for (final i in [0, 2]) {
        expect(results[i].$2, isA<NotificationSyncResultSuccess>().having((e) => e.recent, 'recent', isFalse));
      }
      expect(forum.of('bob'), isEmpty, reason: 'polled moments ago: the plugin would answer 429');
      expect(forum.tokens.toSet(), {'alice', 'carol'});
      expect(await storage.getInt(NotificationPollSlot.key(1000)), at.millisecondsSinceEpoch, reason: 'recorded');
      expect(await storage.getInt(NotificationPollSlot.key(1002)), at.millisecondsSinceEpoch);

      // The auto sync right after does not ask anybody again either.
      forum.requests.clear();
      final next = await tick(now: at.add(const Duration(seconds: 5)));
      expect(next.map((e) => (e as BackgroundSyncSkipped).uid), [1000, 1001, 1002]);
      expect(forum.requests, isEmpty);
    });

    test('a poll that brought nothing is given back; auto sync set to never: every account is fetched', () async {
      await loggedIn(allAccounts: true);
      forum.all['bob'] = _serverError;
      final at = _nextTick();
      await repository().syncAll(accounts: _everyone, pollInterval: const Duration(seconds: 60), now: at).run();
      expect(await storage.getInt(NotificationPollSlot.key(1001)), 0, reason: 'the auto sync may take it after all');

      forum
        ..requests.clear()
        ..all.remove('bob');
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 0);
      final cubit = NotificationSyncAllCubit(
        repository: repository(),
        storageProvider: storage,
        authenticationRepository: AuthenticationRepository(user: _alice),
        infoRepository: NotificationInfoRepository(),
      );
      await cubit.start();
      expect(forum.tokens.toSet(), {'alice', 'bob', 'carol'}, reason: 'nobody else polls: nothing to share');
      await cubit.close();
    });

    test('the cubit asks with the auto sync interval: a second run right after asks nobody', () async {
      await loggedIn(allAccounts: false);
      final infos = NotificationInfoRepository();
      addTearDown(infos.dispose);
      final cubit = NotificationSyncAllCubit(
        repository: repository(),
        storageProvider: storage,
        authenticationRepository: AuthenticationRepository(user: _alice),
        infoRepository: infos,
      );
      addTearDown(cubit.close);
      await cubit.start();
      expect(forum.tokens.toSet(), {'alice', 'bob', 'carol'});
      forum.requests.clear();
      await cubit.start();
      final finished = cubit.state as NotificationSyncAllStateFinished;
      expect(finished.results.map((e) => (e.$2 as NotificationSyncResultSuccess).recent), [true, true, true]);
      expect(forum.requests, isEmpty);
    });

    testWidgets('the progress page says the stored result is shown', (tester) async {
      late String text;
      await tester.pumpWidget(
        TranslationProvider(
          child: Builder(
            builder: (context) {
              text = NotificationSyncAllPage.message(
                context,
                const NotificationSyncResultSuccess(
                  newNotice: 0,
                  newPersonalMessage: 0,
                  newBroadcastMessage: 0,
                  unreadNotice: 1,
                  unreadPersonalMessage: 0,
                  unreadBroadcastMessage: 2,
                  recent: true,
                ),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(text, t.noticePage.syncAllPage.user.recent(unreadNotice: 1, unreadPm: 0, unreadBm: 2));
      expect(text, 'Synced moments ago, the stored result is shown; unread 1/0/2');
    });
  });

  group('payload', () {
    test('the notice page as the account in use, or as a named account; anything else is not ours', () {
      expect(LocalNoticeKeys.parseOpenNotification(LocalNoticeKeys.openNotification), (uid: null));
      expect(LocalNoticeKeys.openNotificationOf(1001), 'openNotification:1001');
      expect(LocalNoticeKeys.parseOpenNotification('openNotification:1001'), (uid: 1001));
      for (final other in [null, '', 'open', 'openNotification:', 'openNotification:x', 'openNotification:0']) {
        expect(LocalNoticeKeys.parseOpenNotification(other), isNull, reason: '$other');
      }
    });

    test('ids of the notifications of the accounts', () {
      expect(isLocalNoticeId(localNoticeId), isTrue);
      expect(isLocalNoticeId(localNoticeIdOf(1)), isTrue);
      expect(isLocalNoticeId(backgroundSyncNotificationId), isFalse);
      expect(localNoticeIdOf(888), isNot(backgroundSyncNotificationId));
      expect(localNoticeIdOf(1000), isNot(localNoticeIdOf(1001)));
      expect(localNoticeIdOf(2147483647), lessThan(1 << 31), reason: 'an Android notification id is an int');
    });
  });

  group('a tap on a notification', () {
    late AuthenticationRepository auth;
    late _SwitchForum switchForum;
    late StreamSubscription<AuthStatus> authLog;

    setUp(() async {
      for (final u in _everyone) {
        await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u));
      }
      await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
      await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
      getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _jar(_alice)));
      switchForum = _SwitchForum();
      auth = AuthenticationRepository(
        user: _alice,
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = switchForum,
          cookie: cookie,
        ),
      );
      authLog = auth.status.listen((s) => _log.add('auth ${s.runtimeType} ${auth.currentUser?.uid}'));
    });

    tearDown(() async {
      await authLog.cancel();
      await auth.dispose();
    });

    Future<({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})?> tap(
      WidgetTester tester,
      String payload,
    ) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Center(child: Text('home'))),
          ),
          GoRoute(
            path: ScreenPaths.notice,
            name: ScreenPaths.notice,
            builder: (_, _) {
              _log.add('notice page as ${auth.currentUser?.uid}');
              return const Scaffold(body: Center(child: Text('notice page')));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: BlocProvider<NotificationBloc>.value(
              value: _Notifications(auth),
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      await _settle(tester);
      final context = tester.element(find.text('home'));
      ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? result;
      // What the home page does with the payload of the tapped notification.
      final open = LocalNoticeKeys.parseOpenNotification(payload)!;
      _log.clear();
      unawaited(
        openNoticePageOfAccount(context, uid: open.uid, popups: PopupRouteObserver()).then((e) => result = e),
      );
      await _settle(tester, rounds: 12);
      return result;
    }

    testWidgets('another account: switch first, its notices reloaded, then the notice page', (tester) async {
      final result = await tap(tester, LocalNoticeKeys.openNotificationOf(_bob.uid!));

      expect(result?.step, LocalNoticeAccountStep.switched);
      expect(result?.action, LocalNoticeTapAction.openNoticePage);
      expect(switchForum.requests, ['bob'], reason: 'the login of Bob checked once, with his cookie');
      expect(auth.currentUser?.uid, 1001);
      expect(settings.currentSettings.loginUid, 1001);
      expect(getIt.get<CookieProvider>().userLoginInfo.uid, 1001);
      expect(find.text('notice page'), findsOneWidget);
      expect(find.text('Switched to Bob'), findsOneWidget, reason: 'the toast of the quick switch');
      // Never Alice's notices while Bob is in use: the switch, then the lists rebuilt for Bob, then the page.
      expect(_log, [
        'auth AuthStatusAuthed 1001',
        'NotificationReloadFromStorageRequested as 1001',
        'notice page as 1001',
      ]);
      expect(isSwitchingAccount, isFalse);
      await _dispose(tester);
    });

    testWidgets('the account in use, or a notification naming none: the notice page right away', (tester) async {
      for (final payload in [LocalNoticeKeys.openNotificationOf(_alice.uid!), LocalNoticeKeys.openNotification]) {
        _log.clear();
        final result = await tap(tester, payload);
        expect(result?.step, LocalNoticeAccountStep.current, reason: payload);
        expect(result?.action, LocalNoticeTapAction.openNoticePage, reason: payload);
        expect(_log, ['notice page as 1000'], reason: payload);
      }
      expect(switchForum.requests, isEmpty, reason: 'no switch');
      expect(auth.currentUser?.uid, 1000);
      await _dispose(tester);
    });

    testWidgets('the switch fails: the notice page is not opened, the account in use stays', (tester) async {
      switchForum.expired.add('bob');
      final result = await tap(tester, LocalNoticeKeys.openNotificationOf(_bob.uid!));

      expect(result?.step, LocalNoticeAccountStep.notSwitched);
      expect(result?.action, isNull);
      expect(find.text('notice page'), findsNothing);
      expect(find.text(t.loginPage.perhapsExpired), findsOneWidget);
      expect(auth.currentUser?.uid, 1000);
      expect(settings.currentSettings.loginUid, 1000);
      expect(_log, isEmpty, reason: "Alice's notice page is not shown for Bob's notification");
      expect(await tester.runAsync(expiredUids), {1001}, reason: 'the expired login of Bob is recorded');
      await _dispose(tester);
    });

    testWidgets('an account no longer on this device: a toast, nothing opened', (tester) async {
      await tester.runAsync(() => storage.deleteCookieByUid(_carol.uid!));
      final result = await tap(tester, LocalNoticeKeys.openNotificationOf(_carol.uid!));

      expect(result?.step, LocalNoticeAccountStep.gone);
      expect(find.text(t.localNotification.accountGone), findsOneWidget);
      expect(find.text('notice page'), findsNothing);
      expect(switchForum.requests, isEmpty);
      expect(auth.currentUser?.uid, 1000);
      await _dispose(tester);
    });

    testWidgets('nobody logged in: the notice page needs a login, as before', (tester) async {
      await tester.runAsync(() async {
        await auth.dispose();
        getIt.get<CookieProvider>().clearUserInfoAndCookie();
        await settings.setValue(SettingsKeys.loginUid, 0);
      });
      auth = AuthenticationRepository();
      final result = await tap(tester, LocalNoticeKeys.openNotificationOf(_bob.uid!));
      expect(result?.step, LocalNoticeAccountStep.current);
      expect(result?.action, LocalNoticeTapAction.needLogin);
      expect(find.text('notice page'), findsNothing);
      expect(switchForum.requests, isEmpty);
      await _dispose(tester);
    });
  });
}
