/// GitHub #173 and #172.
///
/// #173: on Android the in-app auto sync and the background message service each polled every interval, so the
/// forum got two polls a minute and the app API answered the second one with HTTP 429. They now share the poll: the
/// time of the last one is in the shared database and whoever comes within half an interval skips. A polling fetch
/// that did not reach the forum at all (name resolution, timeout, as when the device wakes up) is tried once more.
///
/// #172: a Windows in-app update closed the app and nothing came back. The update script now logs as soon as it
/// starts and once the app exited, waits longer for the exit, and the app copies the script's log into its own log
/// at the next start, so the next report tells where it stopped. Closing the storage can no longer keep the app from
/// exiting.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/notification/utils/poll_slot.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/features/update/repository/windows_update_installer.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Answers `notify` with "nothing new" after failing [offline] times without an answer (or with [status]).
final class _Forum implements HttpClientAdapter {
  _Forum({this.offline = 0, this.status});

  int offline;
  final int? status;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (offline > 0) {
      offline--;
      throw DioException.connectionError(requestOptions: options, reason: 'Unable to resolve host');
    }
    if (status != null) {
      return ResponseBody.fromString(
        '<html></html>',
        status!,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return ResponseBody.fromString(
      jsonEncode({'ok': 1, 'api': 1, 'time': now, 'notices': <Object>[], 'pms': <Object>[], 'announces': <Object>[]}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

void main() {
  late AppDatabase db;
  late StorageProvider storage;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(useConsoleLogs: false));
  });

  setUp(() {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });

  tearDown(() async {
    await getIt.reset();
    await db.close();
  });

  group('#173 one poll per interval', () {
    const minute = Duration(minutes: 1);
    final t0 = DateTime(2026, 10, 7, 12);

    test('the second poller within half an interval skips, the next interval is polled again', () async {
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0), isTrue);
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 2))), isFalse);
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 29))), isFalse);
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.add(const Duration(seconds: 30))), isTrue);
    });

    test('whatever the phase of the two timers, each interval is polled once', () async {
      // The app polls at :00 of every minute, the service at :xx; count the polls that went out over ten minutes.
      for (final offset in [0, 1, 17, 29, 31, 45, 59]) {
        final uid = 100 + offset;
        var polls = 0;
        for (var minuteIndex = 0; minuteIndex < 10; minuteIndex++) {
          final app = t0.add(Duration(minutes: minuteIndex));
          if (await NotificationPollSlot.take(storage, uid, minute, now: app)) polls++;
          if (await NotificationPollSlot.take(storage, uid, minute, now: app.add(Duration(seconds: offset)))) polls++;
        }
        expect(polls, inInclusiveRange(10, 11), reason: 'offset $offset');
      }
    });

    test('accounts are separate, and a clock turned back does not block', () async {
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0), isTrue);
      expect(await NotificationPollSlot.take(storage, 2, minute, now: t0), isTrue);
      expect(await NotificationPollSlot.take(storage, 1, minute, now: t0.subtract(const Duration(hours: 1))), isTrue);
    });

    test('the background service skips a tick right after the app polled', () async {
      final settings = SettingsRepository(storage);
      getIt.registerSingleton<SettingsRepository>(settings);
      await settings.init();
      await settings.setValue(SettingsKeys.loginUid, 7);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
      // The app's auto sync took the poll a moment ago.
      expect(await NotificationPollSlot.take(storage, 7, minute), isTrue);
      final forum = _Forum();
      final outcome = await backgroundSyncTick(
        storage: storage,
        repository: NotificationSyncAllRepository(
          storageProvider: storage,
          notificationRepository: NotificationRepository(storageProvider: storage),
          clientFactory: (cookie) => _client(forum),
          gap: Duration.zero,
        ),
      );
      expect(outcome, isA<BackgroundSyncSkipped>());
      expect((outcome as BackgroundSyncSkipped).reason, contains('polled by the app'));
      expect(forum.requests, isEmpty);
      await settings.dispose();
    });

    test('a poll that did not reach the forum is tried once more', () async {
      // The first attempt reaches nothing: the API and the three pages fail.
      final forum = _Forum(offline: 4);
      final result = await NotificationRepository(
        storageProvider: storage,
        retryDelay: Duration.zero,
      ).fetchNotificationWith(_client(forum), timestamp: 1791346020).run();
      expect(result.isRight(), isTrue);
      expect(forum.requests, hasLength(5));
    });

    test('only once: still offline is a failure', () async {
      final forum = _Forum(offline: 9);
      final result = await NotificationRepository(
        storageProvider: storage,
        retryDelay: Duration.zero,
      ).fetchNotificationWith(_client(forum), timestamp: 1791346020).run();
      expect(result.isLeft(), isTrue);
      // Each attempt asks the API, then the three pages.
      expect(forum.requests, hasLength(8));
    });

    test('an answer with an error status is not retried', () async {
      TsdmAppApi.markUnavailable();
      final forum = _Forum(status: 502);
      final result = await NotificationRepository(
        storageProvider: storage,
        retryDelay: Duration.zero,
      ).fetchNotificationWith(_client(forum), timestamp: 1791346020).run();
      expect(result.isLeft(), isTrue);
      expect(forum.requests, hasLength(3));
    });
  });

  group('#172 Windows update diagnosis', () {
    test('the script logs its start and the exit of the app, and waits up to ten minutes', () {
      const script = WindowsUpdateInstaller.updateScript;
      expect(script, contains("Write-Log ('started, waiting for the app"));
      expect(script, contains("Write-Log 'the app exited'"));
      expect(script, contains('WaitForExit(600000)'));
      expect(script.codeUnits.every((c) => c < 128), isTrue);
      // The log is only written after the marker that lets the app exit.
      expect(script.indexOf(r'Set-Content -LiteralPath $Marker'), lessThan(script.indexOf("Write-Log ('started")));
    });

    test('a script that never reports in leaves what was found in the app log', () async {
      final dir = await Directory.systemTemp.createTemp('tsdm_update_');
      addTearDown(() => dir.delete(recursive: true));
      final app = await Directory(p.join(dir.path, 'app')).create();
      File(p.join(app.path, 'tsdm_client.exe')).writeAsStringSync('old exe');
      File(p.join(app.path, 'flutter_windows.dll')).writeAsStringSync('old engine');
      final updates = (await Directory(p.join(dir.path, 'updates')).create()).path;
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('tsdm_client/tsdm_client.exe', utf8.encode('new exe')))
        ..addFile(ArchiveFile.bytes('tsdm_client/flutter_windows.dll', utf8.encode('new engine')));
      final zip = File(p.join(updates, 'update-125-1.zip'))..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      final logs = <String>[];
      final subscription = talker.stream.listen((e) => logs.add(e.message ?? ''));
      addTearDown(subscription.cancel);
      String? launched;
      final installer = WindowsUpdateInstaller(
        updateDirectory: updates,
        executable: p.join(app.path, 'tsdm_client.exe'),
        startTimeout: const Duration(milliseconds: 300),
        launch: (executable, arguments) async => launched = executable,
        quit: () async => fail('must not quit'),
      );

      await expectLater(
        installer.install(DownloadedUpdate(path: zip.path, version: '1.33.0', versionCode: 125)),
        throwsA(isA<UpdateDownloadException>()),
      );
      await pumpEventQueue();
      // Off Windows the full path does not exist: the name is used as before.
      expect(launched, 'powershell.exe');
      expect(logs.any((e) => e.contains('install 125 from $updates')), isTrue);
      expect(
        logs.any((e) => e.contains('did not report in') && e.contains('script present, marker missing, log missing')),
        isTrue,
      );
    });

    test('the last attempt is copied into the app log once', () async {
      final dir = await Directory.systemTemp.createTemp('tsdm_update_');
      addTearDown(() => dir.delete(recursive: true));
      final logs = <String>[];
      final subscription = talker.stream.listen((e) => logs.add(e.message ?? ''));
      addTearDown(subscription.cancel);
      final installer = WindowsUpdateInstaller(updateDirectory: dir.path);

      await installer.reportLastAttempt();
      await pumpEventQueue();
      expect(logs.where((e) => e.contains('last update attempt')), isEmpty);

      File(p.join(dir.path, WindowsUpdateInstaller.startedMarkerName)).writeAsStringSync('nonce');
      File(p.join(dir.path, WindowsUpdateInstaller.logName)).writeAsStringSync('x started, waiting for the app\n');
      await installer.reportLastAttempt();
      await pumpEventQueue();
      expect(logs.where((e) => e.contains('last update attempt') && e.contains('waiting for the app')), hasLength(1));
      expect(File(p.join(dir.path, WindowsUpdateInstaller.startedMarkerName)).existsSync(), isFalse);

      await installer.reportLastAttempt();
      await pumpEventQueue();
      expect(logs.where((e) => e.contains('last update attempt')), hasLength(1));
    });
  });
}
