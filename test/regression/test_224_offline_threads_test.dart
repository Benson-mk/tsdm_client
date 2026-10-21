/// Offline threads (「離線保存看過的帖子」): the thread pages an account loaded can be read again without network.
///
/// Off by default: nothing is saved and the thread page behaves as before. When on, every thread page the forum served
/// to the account in use is saved as it came (the JSON answer of the app API, or the web page), under the account, the
/// thread, the page and the filters (`ordertype`, `authorid`); the least recently used threads go beyond the chosen
/// number. When a load fails because the forum could not be reached at all (dio's connection error, a socket exception,
/// a connection timeout: not an HTTP error, not a message of the forum), the page saved for the same account and the
/// same request is shown under a banner with the time it was saved, without the reply bar, the rate, the favorite and
/// the other actions that need the network; the other saved pages of the thread can still be opened. The pages of one
/// account are never shown to another account or to a guest, the forum refusing the thread to the account deletes its
/// saved pages, and removing the account deletes all of its pages. The clear cache sheet shows their size and clears
/// them; backups never carry them.
///
/// The thread answers are the fixtures of test_214 (structured answers of the test forum, plugin 2.1.0) and its web
/// page, served to the test accounts; no real account or network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/int.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/offline_thread/utils/thread_refusal.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/models/models.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_cache_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/clear_cache_bottom_sheet.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
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
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/list_app_bar/list_app_bar.dart';

/// The account the fixtures were served to, and another one.
const _alice = UserLoginInfo(username: 'Alice', uid: 35);
const _bob = UserLoginInfo(username: 'Bob', uid: 36);

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

/// The structured answer [name] as the forum serves it to [uid] (0: a guest, or a session that expired).
String _answer(String name, int uid) {
  final json = jsonDecode(_raw(name)) as Map<String, dynamic>;
  json['uid'] = uid;
  return jsonEncode(json);
}

/// The forum's message refusing a thread to a member: no permission (or no such thread).
final String _denied = jsonEncode({
  'ok': 0,
  'api': 1,
  'error': 'message',
  'message': '抱歉，本帖要求阅读权限高于 20 才能浏览',
  'login': 0,
  'schema': 3,
});

/// How the forum fails the next requests.
enum _Failure {
  /// Dio's connection error: no network.
  connection,

  /// A socket exception from the adapter (the Android channel reports an unreachable host so).
  socket,

  /// Timed out while connecting.
  connectTimeout,

  /// Connected, but the answer did not come in time.
  receiveTimeout,

  /// The forum answered with an error status.
  http500,
}

/// The forum: [answer] for every request, or the [failure] set.
final class _Forum implements HttpClientAdapter {
  /// The answer to a request, by its query.
  String Function(Map<String, String> query) answer = (_) => '';

  String contentType = 'application/json; charset=utf-8';

  /// How requests fail, null to answer them.
  _Failure? failure;

  /// Called when a request arrives, before it is answered or failed.
  void Function()? onRequest;

  /// The query of every thread page request.
  final requests = <Map<String, String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final query = options.uri.queryParameters;
    if (query['mod'] == 'viewthread') {
      requests.add(query);
    }
    onRequest?.call();
    switch (failure) {
      case _Failure.connection:
        throw DioException.connectionError(requestOptions: options, reason: 'offline');
      case _Failure.socket:
        throw const SocketException('Network is unreachable');
      case _Failure.connectTimeout:
        throw DioException.connectionTimeout(timeout: const Duration(seconds: 10), requestOptions: options);
      case _Failure.receiveTimeout:
        throw DioException.receiveTimeout(timeout: const Duration(seconds: 10), requestOptions: options);
      case _Failure.http500:
        return ResponseBody.fromString(
          'busy',
          500,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        );
      case null:
        return ResponseBody.fromString(
          answer(query),
          200,
          headers: {
            Headers.contentTypeHeader: [contentType],
          },
        );
    }
  }

  @override
  void close({bool force = false}) {}
}

/// Avatars and images are not downloaded in tests.
final class _OfflineImages implements HttpClientAdapter {
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

/// Cookie row in the format the persistent cookie jar reads back.
Map<String, String> _cookieOf(UserLoginInfo user) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${user.username!.toLowerCase()}; Path=/;_crt=1"}}',
};

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

AppException _left<T>(Either<AppException, T> either) => either.fold((e) => e, (v) => throw StateError('loaded: $v'));

/// Frames with real time in between: the database answers on the real event loop.
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
  int? current;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
    // The backup test opens a second database of the same schema on purpose.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    await settings.init();
    current = _alice.uid;
    forum = _Forum()..answer = (_) => _answer('thread_v3_plain.json', current ?? 0);
    TsdmAppApi.reset();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<void> turnOn({int limit = 50}) async {
    await settings.setValue(SettingsKeys.offlineThreads, true);
    await settings.setValue(SettingsKeys.offlineThreadsLimit, limit);
  }

  /// The offline copies of the account the forum sees now ([current]).
  OfflineThreadRepository offlineCopies() =>
      OfflineThreadRepository(storage: storage, settings: settings, currentUid: () => current);

  Future<Either<AppException, ThreadPageInfo>> load(
    ThreadRepository repo, {
    String tid = '9199345',
    int page = 1,
    bool? reverse,
    String? author,
  }) => repo.fetchThreadPage(tid: tid, pageNumber: page, reverseOrder: reverse, onlyVisibleUid: author).run();

  Future<List<OfflineThreadEntity>> saved() => storage.fetchAllOfflineThreadPages();

  group('setting off', () {
    test('loading the settings while off drops the pages any other path left, never while on', () async {
      Future<void> leaveAPage() => storage.saveOfflineThreadPage(
        uid: 35,
        tid: 1,
        page: 1,
        orderType: 0,
        authorId: 0,
        body: 'a page',
        savedAt: DateTime(2026, 10, 20),
      );
      await leaveAPage();
      final restarted = SettingsRepository(storage);
      addTearDown(restarted.dispose);
      await restarted.init();
      expect(await saved(), isEmpty, reason: 'an imported backup, an older run');

      await turnOn();
      await leaveAPage();
      final again = SettingsRepository(storage);
      addTearDown(again.dispose);
      await again.init();
      expect(await saved(), hasLength(1));
    });

    test('is the default, nothing is saved and a failed load stays a failure', () async {
      expect(settings.currentSettings.offlineThreads, isFalse);
      expect(settings.currentSettings.offlineThreadsLimit, 50);
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      final page = _right(await load(repo));
      expect(page.postList, isNotEmpty);
      expect(page.offlineSavedAt, isNull);
      await copies.pendingWrites;
      expect(await saved(), isEmpty, reason: 'no write while off');

      // Even a page saved before is not read back while off.
      await storage.saveOfflineThreadPage(
        uid: _alice.uid!,
        tid: 9199345,
        page: 1,
        orderType: 0,
        authorId: 0,
        body: _answer('thread_v3_plain.json', _alice.uid!),
        savedAt: DateTime(2026, 10, 20, 8, 30),
      );
      forum.failure = _Failure.connection;
      expect(_left(await load(repo)), isA<HttpHandshakeFailedException>());
      expect(_left(await load(ThreadRepository())), isA<HttpHandshakeFailedException>());
    });
  });

  group('setting on', () {
    setUp(turnOn);

    test('a loaded page is saved as the forum answered it, under the account and the request', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      expect(_right(await load(repo)).postList, isNotEmpty);
      expect(_right(await load(repo, reverse: true)).postList, isNotEmpty);
      expect(_right(await load(repo, author: '32')).postList, isNotEmpty);
      expect(_right(await load(repo, page: 2, reverse: false)).postList, isNotEmpty);
      await copies.pendingWrites;

      final rows = await saved();
      expect(
        rows.map((e) => (e.uid, e.tid, e.page, e.orderType, e.authorId)).toSet(),
        {(35, 9199345, 1, 0, 0), (35, 9199345, 1, 1, 0), (35, 9199345, 1, 0, 32), (35, 9199345, 2, 2, 0)},
      );
      final first = rows.firstWhere((e) => e.orderType == 0 && e.authorId == 0);
      expect(jsonDecode(first.body), jsonDecode(_answer('thread_v3_plain.json', 35)), reason: 'the answer as it came');
      expect(first.size, utf8.encode(first.body).length);
      expect(first.savedAt.isAfter(before), isTrue);
      expect(forum.requests, hasLength(4), reason: 'no extra request');
    });

    test('the web page of a forum without the plugin is saved as it came', () async {
      // The page names the account it was served to in its header (uid 31) and in `discuz_uid`.
      current = 31;
      forum
        ..contentType = 'text/html; charset=utf-8'
        ..answer = (_) => _raw('thread_plain.html');
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      expect(_right(await load(repo)).postList.map((e) => e.postID), contains('3954'));
      await copies.pendingWrites;
      expect((await saved()).single.body, _raw('thread_plain.html'));

      // Served to another account than the one asking (a session that changed hands): not saved for it.
      current = _alice.uid;
      expect(_right(await load(repo)).postList, isNotEmpty);
      await copies.pendingWrites;
      expect((await saved()).map((e) => e.uid), [31]);

      current = 31;

      forum.failure = _Failure.connection;
      final offline = _right(await load(repo));
      expect(offline.offlineSavedAt, isNotNull);
      expect(offline.postList.map((e) => e.postID), contains('3954'));
    });

    test('without network the saved page is built again, marked with its time, without its reply form', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      final online = _right(await load(repo));
      expect(online.replyParameters, isNotNull);
      await copies.pendingWrites;
      final row = (await saved()).single;

      for (final failure in [_Failure.connection, _Failure.socket, _Failure.connectTimeout]) {
        forum.failure = failure;
        final offline = _right(await load(repo));
        expect(offline.offlineSavedAt, row.savedAt, reason: '$failure');
        expect(offline.postList.map((e) => e.postID), online.postList.map((e) => e.postID));
        expect(offline.title, online.title);
        expect(offline.replyParameters, isNull, reason: 'an old form hash, and no network to send it');
      }
    });

    test('an HTTP error, a slow answer or a message of the forum is not answered with a saved page', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      _right(await load(repo));
      await copies.pendingWrites;

      forum.failure = _Failure.http500;
      expect(_left(await load(repo)), isA<HttpHandshakeFailedException>().having((e) => e.statusCode, 'status', 500));
      forum.failure = _Failure.receiveTimeout;
      expect(_left(await load(repo)), isA<HttpHandshakeFailedException>());

      forum
        ..failure = null
        ..answer = (_) => _raw('thread_v3_denied_guest.json');
      final login = _right(await load(repo));
      expect(login.needLogin, isTrue, reason: 'the login prompt of an expired session, as before');
      expect(login.offlineSavedAt, isNull);
      await copies.pendingWrites;
      expect(await saved(), hasLength(1), reason: 'an expired session is no refusal of the thread');
    });

    test('another request is not answered with the saved page', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      _right(await load(repo));
      await copies.pendingWrites;

      forum.failure = _Failure.connection;
      expect(_left(await load(repo, page: 2)), isA<HttpHandshakeFailedException>());
      expect(_left(await load(repo, reverse: true)), isA<HttpHandshakeFailedException>());
      expect(_left(await load(repo, author: '32')), isA<HttpHandshakeFailedException>());
      expect(_left(await load(repo, tid: '9199346')), isA<HttpHandshakeFailedException>());
      expect(
        _left(await repo.fetchThreadPage(pid: '3954').run()),
        isA<HttpHandshakeFailedException>(),
        reason: 'a findpost link does not tell its thread before the forum answers',
      );
      expect(_right(await load(repo)).offlineSavedAt, isNotNull);
    });

    test('the pages of one account are never shown to another account or to a guest', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      _right(await load(repo));
      await copies.pendingWrites;

      forum.failure = _Failure.connection;
      current = _bob.uid;
      expect(_left(await load(repo)), isA<HttpHandshakeFailedException>(), reason: "Alice's copy is not Bob's");
      current = null;
      expect(_left(await load(repo)), isA<HttpHandshakeFailedException>(), reason: 'nor a guest');

      // A guest saves nothing; Bob's own load is saved beside Alice's.
      forum.failure = null;
      expect(_right(await load(repo)).postList, isNotEmpty);
      current = _bob.uid;
      expect(_right(await load(repo)).postList, isNotEmpty);
      await copies.pendingWrites;
      final rows = await saved();
      expect(rows.map((e) => e.uid).toList()..sort(), [35, 36]);
      expect(
        (jsonDecode(rows.firstWhere((e) => e.uid == 36).body) as Map<String, dynamic>)['uid'],
        36,
        reason: 'what the forum served to Bob',
      );

      forum.failure = _Failure.connection;
      final bob = _right(await load(repo));
      expect(bob.offlineSavedAt, isNotNull);
    });

    test('an account switch while the request is out never shows a copy of the previous account', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      _right(await load(repo));
      await copies.pendingWrites;

      forum
        ..failure = _Failure.connection
        ..onRequest = () => current = _bob.uid;
      expect(_left(await load(repo)), isA<HttpHandshakeFailedException>());
    });

    test('the guest page of an expired session is not saved for the account', () async {
      forum.answer = (_) => _answer('thread_v3_plain.json', 0);
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      expect(_right(await load(repo)).postList, isNotEmpty);
      await copies.pendingWrites;
      expect(await saved(), isEmpty);
    });

    test('the forum refusing the thread to the account deletes its saved pages of that thread', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      _right(await load(repo));
      _right(await load(repo, reverse: true));
      forum.answer = (q) => _answer('thread_v3_long_p1.json', current ?? 0);
      _right(await load(repo, tid: '1120'));
      current = _bob.uid;
      forum.answer = (_) => _answer('thread_v3_plain.json', current ?? 0);
      _right(await load(repo));
      await copies.pendingWrites;
      expect(await saved(), hasLength(4));

      current = _alice.uid;
      forum.answer = (_) => _denied;
      final denied = _right(await load(repo));
      expect(denied.havePermission, isFalse);
      await copies.pendingWrites;
      expect(
        (await saved()).map((e) => (e.uid, e.tid)).toSet(),
        {(35, 1120), (36, 9199345)},
        reason: "Alice's other thread and Bob's copy stay",
      );

      forum.failure = _Failure.connection;
      expect(_left(await load(repo)), isA<HttpHandshakeFailedException>());
    });

    test('the least recently used threads go beyond the limit, a thread counts once whatever its pages', () async {
      await turnOn(limit: 2);
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      forum.answer = (q) => switch ((q['tid'], q['page'])) {
        ('1120', '2') => _answer('thread_v3_long_p2.json', current ?? 0),
        ('1120', _) => _answer('thread_v3_long_p1.json', current ?? 0),
        ('9199449', _) => _answer('thread_v3_typed.json', current ?? 0),
        _ => _answer('thread_v3_plain.json', current ?? 0),
      };
      Future<void> step(Future<void> Function() action) async {
        await action();
        await copies.pendingWrites;
        // Distinct use times.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      await step(() async => _right(await load(repo)));
      await step(() async => _right(await load(repo, tid: '1120')));
      await step(() async => _right(await load(repo, tid: '1120', page: 2)));
      expect((await saved()).map((e) => (e.tid, e.page)).toSet(), {(9199345, 1), (1120, 1), (1120, 2)});

      // Read offline: the oldest thread is the most recently used one now.
      forum.failure = _Failure.connection;
      await step(() async => expect(_right(await load(repo)).offlineSavedAt, isNotNull));
      forum.failure = null;
      await step(() async => _right(await load(repo, tid: '9199449')));
      expect(
        (await saved()).map((e) => (e.tid, e.page)).toSet(),
        {(9199345, 1), (9199449, 1)},
        reason: 'both pages of the least recently used thread went',
      );

      // A lower limit applies at once.
      await copies.trim(1);
      expect((await saved()).map((e) => e.tid).toSet(), {9199449});
    });

    test('a page appended from its offline copy marks the thread offline until a load replaces the floors', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      forum.answer = (q) => q['page'] == '2'
          ? _answer('thread_v3_long_p2.json', current ?? 0)
          : _answer('thread_v3_long_p1.json', current ?? 0);
      _right(await load(repo, tid: '1120', page: 2));
      await copies.pendingWrites;

      final bloc = ThreadBloc(
        tid: '1120',
        pid: null,
        onlyVisibleUid: null,
        reverseOrder: null,
        exactOrder: null,
        threadRepository: repo,
      );
      addTearDown(bloc.close);
      bloc.add(const ThreadLoadMoreRequested(1));
      await bloc.stream.firstWhere((s) => s.status == ThreadStatus.success);
      expect(bloc.state.isOffline, isFalse);
      expect(bloc.state.replyParameters, isNotNull);

      forum.failure = _Failure.connection;
      bloc.add(const ThreadLoadMoreRequested(2));
      await bloc.stream.firstWhere((s) => s.status == ThreadStatus.success && s.postList.length == 20);
      await copies.pendingWrites;
      expect(bloc.state.isOffline, isTrue, reason: 'floors on screen came from a copy');
      expect(bloc.state.offlineSavedAt, (await saved()).firstWhere((e) => e.page == 2).savedAt);

      forum.failure = null;
      bloc.add(ThreadRefreshRequested());
      await bloc.stream.firstWhere((s) => s.status == ThreadStatus.success);
      expect(bloc.state.isOffline, isFalse);
      expect(bloc.state.postList.first.postID, '100019');
    });

    test('only the messages that mean the thread is gone or not viewable delete its saved pages', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      Future<int> afterMessage(String message, {int login = 0}) async {
        await storage.clearOfflineThreads();
        forum.answer = (_) => _answer('thread_v3_plain.json', current ?? 0);
        _right(await load(repo));
        await copies.pendingWrites;
        forum.answer = (_) =>
            jsonEncode({'ok': 0, 'api': 1, 'error': 'message', 'message': message, 'login': login, 'schema': 3});
        _right(await load(repo));
        await copies.pendingWrites;
        return (await saved()).length;
      }

      // Each refusal of the forum's language packs, simplified and traditional, as the plugin gives its text.
      final refusals = {
        for (final entry in offlineThreadRefusals.entries)
          for (final sentence in entry.value)
            sentence.replaceAll('{readperm}', '20').replaceAll('{grouptitle}', '新手上路'):
                '${entry.key} ${entry.value.indexOf(sentence)}',
      };
      expect(refusals, hasLength(18));
      for (final message in refusals.keys) {
        expect(await afterMessage(message), 0, reason: refusals[message]);
      }
      // The visible text after a sentence cut at its first tag.
      expect(await afterMessage('抱歉，您需要升级您所在的用户组后才能访问该版块，详细请 点击这里查看。'), 0);
      expect(await afterMessage('您需要拥有以下勋章才能访问这个版块 勋章A 点击进入勋章页面'), 0);

      for (final keep in [
        '抱歉，您的请求太频繁，请稍后再试',
        '抱歉，本站正在维护中，请稍后访问',
        '没有找到帖子',
        '版主设定的自定义提示',
        '抱歉，本帖要求阅读权限高于',
      ]) {
        expect(await afterMessage(keep), 1, reason: keep);
      }
      expect(await afterMessage('抱歉，指定的主题不存在或已被删除或正在被审核', login: 1), 1, reason: 'the login prompt');
    });

    test('the web page of the forum refusing the thread deletes its saved pages too', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      _right(await load(repo));
      await copies.pendingWrites;
      forum.contentType = 'text/html; charset=utf-8';
      String messagePage(String text) =>
          '<html><body><div id="messagetext" class="alert_error"><p>$text</p></div></body></html>';

      forum.answer = (_) => messagePage('抱歉，您的请求太频繁，请稍后再试');
      expect(_right(await load(repo)).havePermission, isFalse);
      await copies.pendingWrites;
      expect(await saved(), hasLength(1));

      forum.answer = (_) => messagePage('\n  抱歉，指定的主題不存在或已被刪除或正在被審核  \n');
      expect(_right(await load(repo)).havePermission, isFalse);
      await copies.pendingWrites;
      expect(await saved(), isEmpty);
    });

    test('a thread keeps its 20 most recently used pages', () async {
      final copies = offlineCopies();
      Future<void> saveAt(int uid, int tid, int page) async {
        copies.save(OfflineThreadKey(uid: uid, tid: tid, page: page, orderType: 0, authorId: 0), 'page $page');
        await copies.pendingWrites;
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }

      for (var page = 1; page <= 20; page++) {
        await saveAt(35, 1, page);
      }
      await saveAt(35, 2, 1);
      await saveAt(36, 1, 1);
      // Page 1 read offline: the most recently used of the thread now.
      await storage.fetchOfflineThreadPage(uid: 35, tid: 1, page: 1, orderType: 0, authorId: 0);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await saveAt(35, 1, 21);
      await saveAt(35, 1, 22);

      final rows = await saved();
      final pages = rows.where((e) => e.uid == 35 && e.tid == 1).map((e) => e.page).toSet();
      expect(pages, hasLength(OfflineThreadRepository.pagesPerThread));
      expect(pages, isNot(contains(2)));
      expect(pages, isNot(contains(3)));
      expect(pages, containsAll([1, 4, 21, 22]));
      expect(rows.where((e) => e.tid == 2 || e.uid == 36), hasLength(2), reason: 'other threads keep theirs');
    });

    test('a saved page that can not be built is not shown', () async {
      await storage.saveOfflineThreadPage(
        uid: 35,
        tid: 9199345,
        page: 1,
        orderType: 0,
        authorId: 0,
        body: _denied,
        savedAt: DateTime(2026, 10, 20),
      );
      forum.failure = _Failure.connection;
      expect(_left(await load(ThreadRepository(offline: offlineCopies()))), isA<HttpHandshakeFailedException>());
    });

    test('the first page lookup of a blocked author reads the saved page too, and never saves one', () async {
      final copies = offlineCopies();
      final repo = ThreadRepository(offline: copies);
      _right(await repo.fetchThreadFirstPage(tid: '9199345').run());
      await copies.pendingWrites;
      expect(await saved(), isEmpty, reason: 'a lookup is no page the user loaded');

      _right(await load(repo, reverse: false));
      await copies.pendingWrites;
      forum.failure = _Failure.connection;
      final first = _right(await repo.fetchThreadFirstPage(tid: '9199345').run());
      expect(first.page.postList.first.postFloor, 1);
    });
  });

  group('a failure to reach the forum is told apart', () {
    RequestOptions options() => RequestOptions(path: '$baseUrl/forum.php');

    test('connection error, connection timeout and socket exception; not the others', () {
      bool offline(Object error) => isNoNetworkFailure(mapException(error, StackTrace.current));

      expect(offline(DioException.connectionError(requestOptions: options(), reason: 'x')), isTrue);
      expect(
        offline(DioException.connectionTimeout(timeout: const Duration(seconds: 1), requestOptions: options())),
        isTrue,
      );
      expect(offline(DioException(requestOptions: options(), error: const SocketException('x'))), isTrue);

      expect(
        offline(DioException.receiveTimeout(timeout: const Duration(seconds: 1), requestOptions: options())),
        isFalse,
      );
      expect(
        offline(
          DioException.badResponse(
            statusCode: 503,
            requestOptions: options(),
            response: Response<dynamic>(requestOptions: options(), statusCode: 503),
          ),
        ),
        isFalse,
      );
      expect(offline(DioException(requestOptions: options(), error: const HandshakeException('x'))), isFalse);
      expect(
        offline(
          DioException(requestOptions: options(), type: DioExceptionType.cancel, error: IdentityChangedException()),
        ),
        isFalse,
        reason: 'a request dropped for another account',
      );
      expect(offline(HttpRequestFailedException(null)), isFalse);
      // Still a failure without status for the callers that tell "nothing came back" so (reply bar, sync retry).
      expect(
        mapException(DioException.connectionError(requestOptions: options(), reason: 'x'), StackTrace.current),
        isA<HttpHandshakeFailedException>().having((e) => e.statusCode, 'status', isNull),
      );
    });
  });

  group('accounts', () {
    Future<void> saveFor(int uid, {int tid = 1}) => storage.saveOfflineThreadPage(
      uid: uid,
      tid: tid,
      page: 1,
      orderType: 0,
      authorId: 0,
      body: 'page of $uid',
      savedAt: DateTime(2026, 10, 20),
    );

    test('removing an account or logging it out deletes its saved pages only', () async {
      for (final uid in [35, 36, 37, 38, 39, 40]) {
        await saveFor(uid);
        await saveFor(uid, tid: 2);
        await storage.saveCookie(username: 'u$uid', uid: uid, cookie: {'Ystv_2132_auth': 'x$uid'});
      }
      Future<Set<int>> uids() async => (await saved()).map((e) => e.uid).toSet();

      await storage.deleteCookieByUid(35);
      expect(await uids(), {36, 37, 38, 39, 40});
      await storage.deleteCookiesByUids([36]);
      expect(await uids(), {37, 38, 39, 40});
      await storage.deleteCookieByUserInfo(const UserLoginInfo(username: 'u37', uid: 37));
      expect(await uids(), {38, 39, 40});
      await storage.deleteUserLoginInfo(38);
      expect(await uids(), {39, 40});

      // Logging out (or forgetting) the account in use goes through the same storage.
      getIt.registerSingleton<CookieProvider>(
        CookieProvider(const UserLoginInfo(username: 'u39', uid: 39), _cookieOf(_alice)),
      );
      final auth = AuthenticationRepository(user: const UserLoginInfo(username: 'u39', uid: 39));
      addTearDown(auth.dispose);
      expect((await auth.forgetCurrentUser().run()).isRight(), isTrue);
      expect(await uids(), {40});
    });

    test('backups never carry the saved pages, and an imported one drops them', () async {
      final dir = Directory.systemTemp.createTempSync('tsdm_offline_backup');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/main.db');
      final fileDb = AppDatabase(NativeDatabase(file));
      final fileStorage = StorageProvider(fileDb, {}, {});
      await fileStorage.saveOfflineThreadPage(
        uid: 35,
        tid: 1,
        page: 1,
        orderType: 0,
        authorId: 0,
        body: 'a page',
        savedAt: DateTime(2026, 10, 20),
      );
      await fileStorage.updateThreadVisitHistory(
        uid: 35,
        tid: 1,
        fid: 2,
        username: 'Alice',
        threadTitle: 'a thread',
        forumName: 'a forum',
        visitTime: DateTime(2026, 10, 20),
      );
      final bytes = await const BackupRepository().exportSanitized(file);
      final exportedFile = File('${dir.path}/exported.db')..writeAsBytesSync(bytes);
      final exported = sqlite.sqlite3.open(exportedFile.path, mode: sqlite.OpenMode.readOnly);
      expect(exported.select('SELECT count(*) AS c FROM offline_thread').first['c'], 0);
      expect(exported.select('SELECT count(*) AS c FROM thread_visit_history').first['c'], 1);
      exported.dispose();

      final imported = sqlite.sqlite3.open(file.path);
      BackupRepository.stripOfflineCopies(imported);
      expect(imported.select('SELECT count(*) AS c FROM offline_thread').first['c'], 0);
      imported.dispose();
      await fileDb.close();
    });
  });

  group('clear cache sheet', () {
    late Directory tmp;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_offline_cache_');
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
          'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
          _ => null,
        },
      );
      await initCache();
      Directory('${tmp.path}/support/log').createSync(recursive: true);
    });

    tearDownAll(() => tmp.delete(recursive: true));

    setUp(() {
      File('${tmp.path}/cache/images/an-image').writeAsBytesSync(List.filled(1000, 1));
      getIt.registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineImages())),
      );
    });

    tearDown(() async => getIt.get<ImageCacheProvider>().dispose());

    Future<void> pumpSheet(WidgetTester tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => showClearCacheBottomSheet(context: context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
    }

    testWidgets('shows the size of the saved pages and clears them alone', (tester) async {
      await tester.runAsync(() async {
        await storage.saveOfflineThreadPage(
          uid: 35,
          tid: 1,
          page: 1,
          orderType: 0,
          authorId: 0,
          body: 'x' * 2048,
          savedAt: DateTime(2026, 10, 20),
        );
        await storage.saveOfflineThreadPage(
          uid: 36,
          tid: 1,
          page: 1,
          orderType: 0,
          authorId: 0,
          body: 'y' * 2048,
          savedAt: DateTime(2026, 10, 20),
        );
      });
      await pumpSheet(tester);

      final tile = find.byKey(const ValueKey('clear-cache-offline-threads'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.text(t.settingsPage.storageSection.offlineThreadsCache)),
        findsOneWidget,
      );
      expect(find.descendant(of: tile, matching: find.text(4096.withSizeHint())), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(tile).value, isFalse, reason: 'not chosen unless asked');

      // Only the offline pages: the image cache stays.
      await tester.tap(find.text(t.settingsPage.storageSection.images));
      await _settle(tester, rounds: 2);
      await tester.tap(tile);
      await _settle(tester, rounds: 2);
      expect(tester.widget<CheckboxListTile>(tile).value, isTrue);
      await tester.tap(find.text(t.general.ok));
      await _settle(tester);

      expect(await tester.runAsync(saved), isEmpty);
      expect(File('${tmp.path}/cache/images/an-image').existsSync(), isTrue, reason: 'no image, emoji or log touched');
      expect(find.text(t.settingsPage.storageSection.clearSuccess), findsOneWidget);
      await _dispose(tester);
    });

    test('the repository adds the size of the saved pages to the files', () async {
      await storage.saveOfflineThreadPage(
        uid: 35,
        tid: 1,
        page: 1,
        orderType: 0,
        authorId: 0,
        body: '測試',
        savedAt: DateTime(2026, 10, 20),
      );
      final info = await const SettingsCacheRepository().calculateCache();
      expect(info.offlineThreadSize, 6, reason: 'UTF-8 bytes');
      expect(info.imageSize, 1000, reason: 'the image files as before');
      expect(
        const CacheClearInfo(
          clearImage: false,
          clearEmoji: false,
          clearLog: false,
          clearOfflineThreads: true,
        ).hasSelected,
        isTrue,
      );
      expect(CacheClearInfo.defaultCacheClearInfo.clearOfflineThreads, isFalse);
    });
  });

  group('thread page', () {
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late AuthenticationRepository auth;

    setUp(() async {
      await storage.saveCookie(username: 'Alice', uid: 35, cookie: _cookieOf(_alice));
      await settings.setValue<int>(SettingsKeys.loginUid, 35);
      await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
      getIt
        ..unregister<NetClientProvider>()
        ..registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)))
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineImages())),
        )
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        );
      forum.answer = (q) => switch (q['page']) {
        '2' => _answer('thread_v3_long_p2.json', current ?? 0),
        _ => _answer('thread_v3_long_p1.json', current ?? 0),
      };
      auth = AuthenticationRepository(user: _alice);
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      ThreadAuthorCache.clear();
    });

    tearDown(() async {
      await settingsBloc.close();
      await blocks.dispose();
      await auth.dispose();
      await getIt.get<ImageCacheProvider>().dispose();
    });

    Future<void> pumpThread(WidgetTester tester, {String tid = '1120'}) async {
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
            builder: (_, _) => ThreadPage(
              threadID: tid,
              findPostID: null,
              pageNumber: '1',
              overrideReverseOrder: false,
              overrideWithExactOrder: null,
            ),
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
    }

    /// When the account last visited the thread, from the history.
    Future<DateTime?> visits() async =>
        (await storage
                .fetchThreadVisitHistoryByUid(
                  _alice.uid!,
                )
                .run())
            .getOrElse((_) => [])
            .firstOrNull
            ?.visitTime;

    ThreadBloc threadBloc(WidgetTester tester) => BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));

    Future<void> jump(WidgetTester tester, int page) async {
      threadBloc(tester).add(ThreadJumpPageRequested(page));
      await _settle(tester);
    }

    /// Wait until [count] pages are saved: the page saves in the background.
    Future<void> savedPages(WidgetTester tester, int count) async {
      for (var i = 0; i < 50; i++) {
        final rows = await tester.runAsync(saved);
        if (rows!.length == count) {
          return;
        }
        await _settle(tester, rounds: 1);
      }
      fail('expected $count saved pages, got ${(await tester.runAsync(saved))!.length}');
    }

    final page1 = find.textContaining('本期年終獎申報', findRichText: true);

    /// The first floor on screen: 100019 on page 1, 100029 on page 2.
    String? firstFloor(WidgetTester tester) => threadBloc(tester).state.postList.firstOrNull?.postID;
    final banner = find.byKey(const ValueKey('thread-offline-banner'));
    final replyBar = find.byKey(const ValueKey('reply-bar-field'));

    /// The labels of the menu [button] opens.
    Future<List<String>> menu(WidgetTester tester, Finder button) async {
      await tester.ensureVisible(button);
      await _settle(tester, rounds: 2);
      await tester.tap(button);
      await _settle(tester, rounds: 2);
      final labels = tester
          .widgetList<Text>(
            find.descendant(of: find.byWidgetPredicate((w) => w is PopupMenuItem), matching: find.byType(Text)),
          )
          .map((e) => e.data ?? '')
          .toList();
      await tester.tapAt(Offset.zero);
      await _settle(tester, rounds: 2);
      return labels;
    }

    /// The labels in the action menu of the first floor.
    Future<List<String>> floorMenu(WidgetTester tester) => menu(
      tester,
      find
          .descendant(
            of: find.byType(PostCard).first,
            matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
          )
          .first,
    );

    testWidgets('off: no copy, an offline load fails as before', (tester) async {
      await pumpThread(tester);
      expect(page1, findsWidgets);
      await _settle(tester);
      expect(await tester.runAsync(saved), isEmpty);

      forum.failure = _Failure.connection;
      await jump(tester, 1);
      expect(banner, findsNothing);
      expect(find.text(t.general.failedToLoad), findsOneWidget, reason: 'the floors stay, the failure is told');
      await _dispose(tester);
    });

    testWidgets('on: the saved pages are read without network, under the banner, without network actions', (
      tester,
    ) async {
      await tester.runAsync(turnOn);
      await pumpThread(tester);
      expect(page1, findsWidgets);
      expect(banner, findsNothing);
      expect(replyBar, findsOneWidget);
      expect(await floorMenu(tester), containsAll([t.postCard.reply, t.postReport.menu]));
      await jump(tester, 2);
      expect(firstFloor(tester), '100029');
      await savedPages(tester, 2);
      final savedAt = (await tester.runAsync(saved))!.firstWhere((e) => e.page == 1).savedAt;
      final visited = await tester.runAsync(visits);
      expect(visited, isNotNull, reason: 'the forum page is a visit');

      forum.failure = _Failure.connection;
      await jump(tester, 1);
      expect(firstFloor(tester), '100019', reason: 'the saved page 1');
      expect(banner, findsOneWidget);
      expect(find.text(t.threadPage.offlineBanner(time: savedAt.yyyyMMDDHHMM())), findsOneWidget);
      expect(replyBar, findsNothing, reason: 'no reply without network');
      expect(threadBloc(tester).state.replyParameters, isNull);
      final menu = await floorMenu(tester);
      expect(menu, isNot(contains(t.postCard.reply)));
      expect(menu, isNot(contains(t.postCard.rate)));
      expect(menu, isNot(contains(t.postCard.edit)));
      expect(menu, isNot(contains(t.postReport.menu)));

      // The other saved page of the thread opens too; a page never saved fails as before, the floors stay.
      await jump(tester, 2);
      expect(firstFloor(tester), '100029');
      expect(banner, findsOneWidget);
      await jump(tester, 3);
      expect(firstFloor(tester), '100029');
      expect(find.text(t.general.failedToLoad), findsOneWidget);
      expect(forum.requests.map((e) => e['page']), ['1', '2', '1', '2', '3'], reason: 'every load asked the forum');
      expect(await tester.runAsync(visits), visited, reason: 'an offline copy is no visit');

      // The network is back: the page from the forum, the actions again.
      forum.failure = null;
      await jump(tester, 1);
      expect(banner, findsNothing);
      expect(replyBar, findsOneWidget);
      expect(threadBloc(tester).state.isOffline, isFalse);
      await _dispose(tester);
    });

    testWidgets('the favorite and the share of the app bar menu need the network', (tester) async {
      await tester.runAsync(turnOn);
      await pumpThread(tester);
      await savedPages(tester, 1);

      Future<List<String>> appBarMenu() => menu(
        tester,
        find.descendant(of: find.byType(ListAppBar), matching: find.byWidgetPredicate((w) => w is PopupMenuButton)),
      );

      expect(await appBarMenu(), contains(t.threadPage.favorite.add));
      forum.failure = _Failure.connection;
      await jump(tester, 1);
      expect(banner, findsOneWidget);
      final offline = await appBarMenu();
      expect(offline, isNot(contains(t.threadPage.favorite.add)));
      expect(offline, isNot(contains(t.threadPage.shareToFriend.title)));
      expect(offline, contains(t.threadPage.copyTid(tid: '1120')));
      await _dispose(tester);
    });

    testWidgets('the purchase and the red packet need the network', (tester) async {
      await tester.runAsync(turnOn);
      // The paid thread, with a red packet on its first floor.
      forum.answer = (_) {
        final json = jsonDecode(_answer('thread_v3_paid.json', current ?? 0)) as Map<String, dynamic>;
        ((json['posts'] as List).first as Map<String, dynamic>)['packet_html'] =
            '<div id="ts_packet"><a href="plugin.php?id=tsdm_packet:packet&amp;pid=3055"> '
            '<img src="static/image/post/rp-1.svg" /></a></div>';
        return jsonEncode(json);
      };
      await pumpThread(tester, tid: '9199057');
      await savedPages(tester, 1);
      final purchase = find.widgetWithIcon(OutlinedButton, FontAwesomeIcons.coins);
      final openPacket = find.text(t.packetCard.open);
      expect(purchase, findsOneWidget);
      expect(openPacket, findsOneWidget);

      forum.failure = _Failure.connection;
      await jump(tester, 1);
      expect(banner, findsOneWidget);
      expect(purchase, findsNothing);
      expect(openPacket, findsNothing);
      expect(find.text(t.packetCard.title), findsOneWidget, reason: 'the packet itself is still told');
      await _dispose(tester);
    });

    testWidgets('the poll vote needs the network, its results stay', (tester) async {
      await tester.runAsync(turnOn);
      // Without the images of the floors (medals in the author column): nothing is downloaded in tests.
      forum.answer = (_) {
        final json = jsonDecode(_answer('thread_v3_poll.json', current ?? 0)) as Map<String, dynamic>;
        for (final post in (json['posts'] as List).cast<Map<String, dynamic>>()) {
          for (final field in ['author_html', 'body_html', 'signature_html']) {
            if (post[field] case final String html) {
              post[field] = html.replaceAll(RegExp('<img[^>]*>'), '');
            }
          }
        }
        return jsonEncode(json);
      };
      await pumpThread(tester, tid: '9199099');
      await savedPages(tester, 1);
      final vote = find.text(t.pollVoting.submit);
      final refresh = find.text(t.pollVoting.refresh);
      expect(vote, findsOneWidget);
      expect(refresh, findsOneWidget);

      forum.failure = _Failure.connection;
      await jump(tester, 1);
      expect(banner, findsOneWidget);
      expect(vote, findsNothing);
      expect(refresh, findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(RadioListTile<String>), findsNothing);
      expect(find.text(t.pollCard.title), findsOneWidget);
      await _dispose(tester);
    });
  });
}
