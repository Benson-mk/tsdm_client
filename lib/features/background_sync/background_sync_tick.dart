import 'dart:async';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/notification/utils/poll_slot.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// How long one tick of the background message service may take before it is given up.
///
/// Above the worst case of the client's own timeouts with the one retry (GitHub #173): the deadline is for a fetch
/// the system holds past them.
const backgroundSyncDeadline = Duration(minutes: 6);

/// The settings one background sync reads fresh from the database.
///
/// The service runs in its own isolate: nothing in memory tells it about a change made in the app, so every tick
/// reads what it needs from the settings table instead of caching a copy.
typedef BackgroundSyncSettings = ({bool enabled, int intervalSeconds, int loginUid, String locale});

/// Read [BackgroundSyncSettings] from [storage].
Future<BackgroundSyncSettings> readBackgroundSyncSettings(StorageProvider storage) async => (
  enabled:
      await storage.getBool(SettingsKeys.enableBackgroundMessageService.name) ??
      SettingsKeys.enableBackgroundMessageService.defaultValue,
  intervalSeconds:
      await storage.getInt(SettingsKeys.autoSyncNoticeSeconds.name) ?? SettingsKeys.autoSyncNoticeSeconds.defaultValue,
  loginUid: await storage.getInt(SettingsKeys.loginUid.name) ?? SettingsKeys.loginUid.defaultValue,
  locale: await storage.getString(SettingsKeys.locale.name) ?? SettingsKeys.locale.defaultValue,
);

/// What one tick of the background message service ended with.
sealed class BackgroundSyncOutcome {
  const BackgroundSyncOutcome();
}

/// The switch is off: the service has no reason to stay alive.
final class BackgroundSyncDisabled extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncDisabled();
}

/// Nothing was fetched this time; [reason] says why.
final class BackgroundSyncSkipped extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncSkipped(this.reason);

  /// Why the tick fetched nothing.
  final String reason;
}

/// The fetch finished for settings that no longer hold: the account was switched, or auto sync was set to never,
/// while it was in flight. What it fetched is stored for that account like the sync of all accounts would, but
/// nothing is announced: the push would name the wrong account and open the current one's messages.
final class BackgroundSyncStale extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncStale(this.reason);

  /// What changed while the fetch was in flight.
  final String reason;
}

/// Read the network settings again and, when the app follows the system proxy, ask the platform for it.
///
/// The service isolate keeps its own [SettingsRepository]; its snapshot is from the moment the service started,
/// so a proxy the user set or switched off in the app since, or a fresh app start, never reached it. The system
/// proxy lives on the platform side and is only known once [updateProxy] (the isolate's `ProxyProvider`) asked for
/// it, which the app does at its own start and the service did not: with "use the detected proxy" on, the client
/// was built with an empty proxy and went direct. Called before every fetch; a failure is the caller's, see
/// [backgroundSyncTick].
Future<void> refreshBackgroundNetworkSettings({
  required SettingsRepository settings,
  required Future<void> Function() updateProxy,
}) async {
  await settings.init();
  final current = settings.currentSettings;
  if (current.netClientUseProxy && current.useDetectedProxyWhenStartup) {
    await updateProxy();
  }
}

/// The current account was synced; [result] is what the shared sync produced for it.
final class BackgroundSyncDone extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncDone({required this.uid, required this.result});

  /// The account that was synced.
  final int uid;

  /// Outcome of the sync of that account.
  final NotificationSyncResult result;

  /// What a push notification should announce, null when nothing was new.
  NotificationAutoSyncInfo? get latest => switch (result) {
    NotificationSyncResultSuccess(:final latest) => latest,
    _ => null,
  };
}

/// One tick of the Android background message service (#80).
///
/// Reads the settings, then fetches and stores the current account's notifications through [repository], the very
/// path the "sync all accounts" action uses: same client (cookies, antitheft, proxy, user agent), same storage, same
/// read-state reconciliation and the same notion of what is new. Because the rows land in the shared database, the
/// in-app sync that runs next finds nothing new and does not announce them a second time, and vice versa.
///
/// The service is meant to follow the in-app auto sync: with the interval set to never, or nobody logged in, the tick
/// fetches nothing.
///
/// The app's own auto sync shares the poll ([NotificationPollSlot], GitHub #173): a tick within half an interval of
/// its last poll fetches nothing; a tick that fetched nothing gives the poll back. [now] is the time of the tick,
/// the current time when not given.
///
/// A fetch not answered within [deadline] is given up ([BackgroundSyncSkipped]) so the next tick fetches afresh;
/// what it brings when it does answer is stored like any fetch, so it is handed to [onLate] as the outcome it would
/// have been: a message stored without its notification would never be announced, the next fetch finds it known.
///
/// [prepareNetwork] runs right before the fetch ([refreshBackgroundNetworkSettings] in the service). When it throws
/// the tick fetches nothing: the proxy the user asked for could not be read, and fetching without it would be a
/// direct connection the user did not choose.
///
/// The settings are read again once the fetch is back: the app may have switched accounts or set auto sync to
/// never meanwhile, and a push for an account that is no longer the current one would open the wrong messages
/// ([BackgroundSyncStale]); the switch turned off meanwhile ends the service ([BackgroundSyncDisabled]).
Future<BackgroundSyncOutcome> backgroundSyncTick({
  required StorageProvider storage,
  required NotificationSyncAllRepository repository,
  Future<void> Function()? prepareNetwork,
  DateTime? now,
  Duration deadline = backgroundSyncDeadline,
  void Function(BackgroundSyncOutcome late)? onLate,
}) async {
  final settings = await readBackgroundSyncSettings(storage);
  if (!settings.enabled) {
    return const BackgroundSyncDisabled();
  }
  if (settings.intervalSeconds <= 0) {
    return const BackgroundSyncSkipped('auto sync is off');
  }
  if (settings.loginUid <= 0) {
    return const BackgroundSyncSkipped('not logged in');
  }
  if (prepareNetwork != null) {
    try {
      await prepareNetwork();
    } on Object catch (e) {
      return BackgroundSyncSkipped('network settings unavailable: $e');
    }
  }
  // The app may have logged in, out or switched accounts since the last tick.
  await storage.refreshCookieCache();
  // The app's own auto sync may have polled moments ago (GitHub #173). Taken only now, with everything a fetch
  // needs in hand: taken earlier, a tick that could not fetch kept the app from polling too.
  final uid = settings.loginUid;
  final slot = await NotificationPollSlot.take(storage, uid, Duration(seconds: settings.intervalSeconds), now: now);
  if (slot == null) {
    return const BackgroundSyncSkipped('polled by the app moments ago');
  }
  var fetched = false;
  try {
    final run = repository.syncAll(accounts: [UserLoginInfo(username: null, uid: uid)]).run();
    var timedOut = false;
    final info = await run.timeout(
      deadline,
      onTimeout: () {
        timedOut = true;
        return left(HttpRequestFailedException(null));
      },
    );
    if (timedOut) {
      // A fetch the system holds (the device asleep) hung for hours and every later tick waited behind it: past
      // the deadline this tick is over. What it brings later is announced by `onLate`, see above.
      talker.warning('background sync: no answer within ${deadline.inSeconds}s, giving up this tick');
      unawaited(
        run.then(
          (late) async => onLate?.call(await _outcomeOf(late, storage, settings)),
          onError: (Object e) => talker.warning('background sync: the fetch given up failed later: $e'),
        ),
      );
      return BackgroundSyncSkipped('no answer within ${deadline.inSeconds}s');
    }
    final outcome = await _outcomeOf(info, storage, settings);
    fetched = outcome is BackgroundSyncDone && outcome.result is NotificationSyncResultSuccess;
    return outcome;
  } finally {
    if (!fetched) {
      // Nothing came of this poll: the app's own sync may take the interval after all.
      await NotificationPollSlot.release(storage, uid, slot);
    }
  }
}

/// The outcome of a finished fetch, against the settings read again now (see [backgroundSyncTick]).
Future<BackgroundSyncOutcome> _outcomeOf(
  Either<AppException, NotificationSyncAllInfo> info,
  StorageProvider storage,
  BackgroundSyncSettings settings,
) async {
  final after = await readBackgroundSyncSettings(storage);
  if (!after.enabled) {
    return const BackgroundSyncDisabled();
  }
  if (after.loginUid != settings.loginUid) {
    return const BackgroundSyncStale('account switched during the fetch');
  }
  if (after.intervalSeconds <= 0) {
    return const BackgroundSyncStale('auto sync set to never during the fetch');
  }
  return switch (info) {
    Left(:final value) => BackgroundSyncSkipped('sync failed: $value'),
    Right(:final value) => BackgroundSyncDone(
      uid: settings.loginUid,
      result:
          value.finished.where((e) => e.$1.uid == settings.loginUid).lastOrNull?.$2 ??
          const NotificationSyncResultFailed('no result'),
    ),
  };
}
