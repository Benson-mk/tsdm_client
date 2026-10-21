import 'dart:async';

import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The other accounts' part of the in-app auto sync, when every logged-in account is asked for
/// (`SettingsKeys.backgroundSyncAllAccounts`): Android and Windows, where the auto sync posts system notifications.
///
/// The in-app auto sync (`AutoNotificationCubit`) polls the account in use; after each of its polls it calls [poll]
/// without waiting, so an account switch or a login never waits for the other accounts. One round at a time
/// ([autoSyncOtherAccountsTick]); a poll while the previous round still runs is skipped.
///
/// Each account that was synced is reported the way the background message service reports it: `announce` posts the
/// notification of something new (it names the account, a tap opens it as that account), and [synced] carries the
/// account's unread counts in the service's `synced` shape, so the bridge that brings the service's rows into the app
/// also reloads the notice page when the account switched to meanwhile is the one synced.
final class OtherAccountsAutoSync with LoggerMixin {
  /// Constructor.
  ///
  /// [repository] is this class's own (its progress stream is not the one of the sync of all accounts), disposed with
  /// it.
  OtherAccountsAutoSync({
    required StorageProvider storage,
    required NotificationSyncAllRepository repository,
    required Future<void> Function(BackgroundSyncDone done) announce,
    this.gap = backgroundSyncAccountGap,
    this.deadline = backgroundSyncDeadline,
  }) : _storage = storage,
       _repository = repository,
       _announce = announce;

  final StorageProvider _storage;
  final NotificationSyncAllRepository _repository;
  final Future<void> Function(BackgroundSyncDone done) _announce;

  /// Pause before each account, see [autoSyncOtherAccountsTick].
  final Duration gap;

  /// How long one account's fetch may take, see [autoSyncOtherAccountsTick].
  final Duration deadline;

  final _synced = StreamController<Map<String, dynamic>?>.broadcast();

  /// Accounts synced, in the shape of the background service's `synced` event: `uid`, `notice`, `personalMessage`,
  /// `broadcastMessage` (the account's unread counts).
  Stream<Map<String, dynamic>?> get synced => _synced.stream;

  Future<List<BackgroundSyncOutcome>>? _running;

  var _disposed = false;

  /// Whether a round is running.
  bool get isRunning => _running != null;

  /// Poll the other accounts once, unless a round is still running; the outcomes of this round, empty when skipped.
  ///
  /// [now] is the time of the poll (the current time by default), for the poll slots.
  Future<List<BackgroundSyncOutcome>> poll({DateTime? now}) {
    if (_disposed) {
      return Future.value(const []);
    }
    if (_running != null) {
      debug('other accounts: the previous round is still running, skipped');
      return Future.value(const []);
    }
    final round = _round(now);
    _running = round;
    return round.whenComplete(() => _running = null);
  }

  Future<List<BackgroundSyncOutcome>> _round(DateTime? now) async {
    try {
      return await autoSyncOtherAccountsTick(
        storage: _storage,
        repository: _repository,
        now: now,
        gap: gap,
        deadline: deadline,
        onLate: (late) => unawaited(_report(late)),
        onOutcome: _report,
      );
    } on Object catch (e, st) {
      handleRaw(e, st);
      return const [];
    }
  }

  Future<void> _report(BackgroundSyncOutcome outcome) async {
    if (_disposed) {
      return;
    }
    try {
      switch (outcome) {
        case BackgroundSyncDone(:final uid, :final result):
          debug('other accounts: ${result.runtimeType} for uid ${"$uid".obscured(4)}');
          if (result case NotificationSyncResultSuccess(:final latest)) {
            if (latest != null) {
              await _announce(outcome);
            }
            if (!_synced.isClosed) {
              _synced.add({
                'uid': uid,
                'notice': result.unreadNotice,
                'personalMessage': result.unreadPersonalMessage,
                'broadcastMessage': result.unreadBroadcastMessage,
              });
            }
          }
        case BackgroundSyncSkipped(:final reason, :final uid):
          debug('other accounts: skipped${uid == null ? '' : ' uid ${"$uid".obscured(4)}'}, $reason');
        case BackgroundSyncStale(:final reason, :final uid):
          info('other accounts: not announced${uid == null ? '' : ' uid ${"$uid".obscured(4)}'}, $reason');
        case BackgroundSyncDisabled():
          // The switch of the background message service plays no part in the app.
          break;
      }
    } on Object catch (e, st) {
      handleRaw(e, st);
    }
  }

  /// Wait for a running round, then stop reporting and close.
  Future<void> dispose() async {
    await _running;
    _disposed = true;
    await _synced.close();
    await _repository.dispose();
  }
}
