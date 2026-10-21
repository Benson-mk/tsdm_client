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

/// Pause between the fetches of two accounts in one tick, when every saved account is polled.
///
/// Same as the sync of all accounts (`NotificationSyncAllRepository.gap`): the plugin takes one call per action and
/// account within its interval, and the forum answered 429 when several accounts asked at once.
const backgroundSyncAccountGap = Duration(seconds: 2);

/// The settings one background sync reads fresh from the database.
///
/// The service runs in its own isolate: nothing in memory tells it about a change made in the app, so every tick
/// reads what it needs from the settings table instead of caching a copy. `allAccounts` is
/// `SettingsKeys.backgroundSyncAllAccounts`, see [backgroundSyncAccountsTick].
typedef BackgroundSyncSettings = ({bool enabled, int intervalSeconds, int loginUid, String locale, bool allAccounts});

/// Read [BackgroundSyncSettings] from [storage].
Future<BackgroundSyncSettings> readBackgroundSyncSettings(StorageProvider storage) async => (
  enabled:
      await storage.getBool(SettingsKeys.enableBackgroundMessageService.name) ??
      SettingsKeys.enableBackgroundMessageService.defaultValue,
  intervalSeconds:
      await storage.getInt(SettingsKeys.autoSyncNoticeSeconds.name) ?? SettingsKeys.autoSyncNoticeSeconds.defaultValue,
  loginUid: await storage.getInt(SettingsKeys.loginUid.name) ?? SettingsKeys.loginUid.defaultValue,
  locale: await storage.getString(SettingsKeys.locale.name) ?? SettingsKeys.locale.defaultValue,
  allAccounts:
      await storage.getBool(SettingsKeys.backgroundSyncAllAccounts.name) ??
      SettingsKeys.backgroundSyncAllAccounts.defaultValue,
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
  const BackgroundSyncSkipped(this.reason, {this.uid});

  /// Why the tick fetched nothing.
  final String reason;

  /// The account skipped, null when the whole tick was.
  final int? uid;
}

/// The fetch finished for settings that no longer hold: the account was switched, or auto sync was set to never,
/// while it was in flight. What it fetched is stored for that account like the sync of all accounts would, but
/// nothing is announced: the push would name the wrong account and open the current one's messages.
final class BackgroundSyncStale extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncStale(this.reason, {this.uid});

  /// What changed while the fetch was in flight.
  final String reason;

  /// The account fetched.
  final int? uid;
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

/// An account was synced; [result] is what the shared sync produced for it.
final class BackgroundSyncDone extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncDone({required this.uid, required this.result, this.username, this.named = false});

  /// The account that was synced.
  final int uid;

  /// Its name as stored on this device, null when unknown.
  final String? username;

  /// Whether every saved account is announced (`SettingsKeys.backgroundSyncAllAccounts` on when the fetch came back):
  /// the notification then names the account and is the account's own, see `LocalNoticeAccount.named`.
  final bool named;

  /// Outcome of the sync of that account.
  final NotificationSyncResult result;

  /// What a push notification should announce, null when nothing was new.
  NotificationAutoSyncInfo? get latest => switch (result) {
    NotificationSyncResultSuccess(:final latest) => latest,
    _ => null,
  };
}

/// One tick of the Android background message service (#80), for the account in use.
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
///
/// This is the whole tick while `SettingsKeys.backgroundSyncAllAccounts` is off; [backgroundSyncAccountsTick] runs
/// it then, and polls every saved account otherwise.
Future<BackgroundSyncOutcome> backgroundSyncTick({
  required StorageProvider storage,
  required NotificationSyncAllRepository repository,
  Future<void> Function()? prepareNetwork,
  DateTime? now,
  Duration deadline = backgroundSyncDeadline,
  void Function(BackgroundSyncOutcome late)? onLate,
}) async {
  final settings = await readBackgroundSyncSettings(storage);
  if (_notToPoll(settings) case final skipped?) {
    return skipped;
  }
  if (await _prepare(prepareNetwork) case final skipped?) {
    return skipped;
  }
  // The app may have logged in, out or switched accounts since the last tick.
  await storage.refreshCookieCache();
  final polled = await _pollAccount(
    storage: storage,
    repository: repository,
    settings: settings,
    account: UserLoginInfo(username: null, uid: settings.loginUid),
    now: now,
    deadline: deadline,
    onLate: onLate,
  );
  return polled.outcome;
}

/// One tick of the Android background message service over the accounts it polls.
///
/// With `SettingsKeys.backgroundSyncAllAccounts` off this is [backgroundSyncTick] and nothing else: the account in
/// use, exactly as before, its outcome the only one.
///
/// With it on, every account saved on this device is polled, one after another: the account in use first, then the
/// others in the order they are stored. Each account is fetched as the sync of all accounts fetches it (its own
/// client and cookie, its own stored rows, fetch bound, deleted conversations and block list, and the plugin's `seen`
/// posted with its own form hash), and takes its own poll ([NotificationPollSlot] of its uid): an account the app
/// polled moments ago is skipped, the others still run. Between two accounts that reached the forum the tick waits
/// [gap] ([backgroundSyncAccountGap]); the plugin limits each action per account, the forum the bursts.
///
/// What goes wrong for one account stays with it: an expired session is recorded for that account only (the sync of
/// all accounts marks it, as for the account in use; the account in use is never logged out), a failure or a 429 is
/// its own outcome, and the next account runs. Another account whose login is known to be expired is not polled again
/// until it logs in again; the account in use is polled as before. A fetch given up at [deadline] ends the round
/// though: the network the system holds would hold every account after it as long, and the next tick polls them.
///
/// Every outcome is handed to [onOutcome] as soon as its account is done (the service announces it then), and the
/// list of them is returned. A notification of one of them names its account ([BackgroundSyncDone.named]); a fetch
/// of an account that is no longer the account in use when it comes back is announced as well, since its
/// notification opens that account. The settings are read again before each account after the first: switched off
/// meanwhile ([BackgroundSyncDisabled], also when a fetch comes back), or back to the account in use only, the round
/// ends there.
Future<List<BackgroundSyncOutcome>> backgroundSyncAccountsTick({
  required StorageProvider storage,
  required NotificationSyncAllRepository repository,
  Future<void> Function()? prepareNetwork,
  DateTime? now,
  Duration deadline = backgroundSyncDeadline,
  Duration gap = backgroundSyncAccountGap,
  void Function(BackgroundSyncOutcome late)? onLate,
  FutureOr<void> Function(BackgroundSyncOutcome outcome)? onOutcome,
}) async {
  final outcomes = <BackgroundSyncOutcome>[];
  Future<void> add(BackgroundSyncOutcome outcome) async {
    outcomes.add(outcome);
    await onOutcome?.call(outcome);
  }

  final settings = await readBackgroundSyncSettings(storage);
  if (!settings.allAccounts) {
    await add(
      await backgroundSyncTick(
        storage: storage,
        repository: repository,
        prepareNetwork: prepareNetwork,
        now: now,
        deadline: deadline,
        onLate: onLate,
      ),
    );
    return outcomes;
  }
  if (_notToPoll(settings) case final skipped?) {
    await add(skipped);
    return outcomes;
  }
  if (await _prepare(prepareNetwork) case final skipped?) {
    await add(skipped);
    return outcomes;
  }
  await storage.refreshCookieCache();
  final accounts = await _accountsToPoll(storage, settings.loginUid);
  var reachedForum = false;
  for (final (index, account) in accounts.indexed) {
    if (reachedForum && gap > Duration.zero) {
      await Future<void>.delayed(gap);
    }
    if (index > 0) {
      // The app may have switched the service off, or back to the account in use only, while the round ran.
      final latest = await readBackgroundSyncSettings(storage);
      if (_notToPoll(latest) case final stop?) {
        await add(stop);
        break;
      }
      if (!latest.allAccounts) {
        await add(const BackgroundSyncSkipped('every account switched off during the round'));
        break;
      }
    }
    final polled = await _pollAccount(
      storage: storage,
      repository: repository,
      settings: settings,
      account: account,
      now: now,
      deadline: deadline,
      onLate: onLate,
    );
    await add(polled.outcome);
    if (polled.outcome is BackgroundSyncDisabled) {
      break;
    }
    if (polled.givenUp) {
      for (final rest in accounts.skip(index + 1)) {
        await add(BackgroundSyncSkipped('a fetch before it was given up', uid: rest.uid));
      }
      break;
    }
    reachedForum = polled.requested;
  }
  return outcomes;
}

/// Why nothing is polled for [settings], null when the tick may poll.
BackgroundSyncOutcome? _notToPoll(BackgroundSyncSettings settings) {
  if (!settings.enabled) {
    return const BackgroundSyncDisabled();
  }
  if (settings.intervalSeconds <= 0) {
    return const BackgroundSyncSkipped('auto sync is off');
  }
  if (settings.loginUid <= 0) {
    return const BackgroundSyncSkipped('not logged in');
  }
  return null;
}

/// Run [prepareNetwork]; what the tick ends with when it throws, null when the tick may fetch.
Future<BackgroundSyncOutcome?> _prepare(Future<void> Function()? prepareNetwork) async {
  if (prepareNetwork == null) {
    return null;
  }
  try {
    await prepareNetwork();
    return null;
  } on Object catch (e) {
    return BackgroundSyncSkipped('network settings unavailable: $e');
  }
}

/// The accounts a tick with every account on polls: the account in use [loginUid] first, as the in-app sync and the
/// tick for it alone poll it (also while its login is marked expired); then every other account saved on this device
/// with a name and a uid, as the sync of all accounts lists them, except those whose login is known to be expired.
Future<List<UserLoginInfo>> _accountsToPoll(StorageProvider storage, int loginUid) async {
  final stored = (await storage.getAllUsers())
      .where((e) => e.uid != null && e.uid! > 0 && e.username != null && e.username!.isNotEmpty)
      .toList();
  final expired = (await storage.fetchExpiredSessions()).map((e) => e.user.uid).toSet();
  final current = stored.where((e) => e.uid == loginUid).firstOrNull ?? UserLoginInfo(username: null, uid: loginUid);
  final others = stored.where((e) => e.uid != loginUid && !expired.contains(e.uid));
  final skipped = stored.where((e) => e.uid != loginUid && expired.contains(e.uid)).length;
  if (skipped > 0) {
    talker.debug('background sync: $skipped account(s) with an expired login not polled');
  }
  return [current, ...others];
}

/// What polling one account brought: the `outcome`; whether a request was sent (`requested`, the poll was taken);
/// whether the fetch was given up at the deadline (`givenUp`).
typedef _Polled = ({BackgroundSyncOutcome outcome, bool requested, bool givenUp});

/// Take the poll of [account], fetch and store its notifications through [repository] and tell what came of it, see
/// [backgroundSyncTick]. [settings] are the ones the tick started with.
Future<_Polled> _pollAccount({
  required StorageProvider storage,
  required NotificationSyncAllRepository repository,
  required BackgroundSyncSettings settings,
  required UserLoginInfo account,
  required DateTime? now,
  required Duration deadline,
  required void Function(BackgroundSyncOutcome late)? onLate,
}) async {
  final uid = account.uid!;
  // The app's own auto sync may have polled moments ago (GitHub #173). Taken only now, with everything a fetch
  // needs in hand: taken earlier, a tick that could not fetch kept the app from polling too.
  final slot = await NotificationPollSlot.take(storage, uid, Duration(seconds: settings.intervalSeconds), now: now);
  if (slot == null) {
    return (
      outcome: BackgroundSyncSkipped('polled by the app moments ago', uid: settings.allAccounts ? uid : null),
      requested: false,
      givenUp: false,
    );
  }
  var fetched = false;
  try {
    final run = repository.syncAll(accounts: [account]).run();
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
          (late) async => onLate?.call(await _outcomeOf(late, storage, settings, account)),
          onError: (Object e) => talker.warning('background sync: the fetch given up failed later: $e'),
        ),
      );
      return (
        outcome: BackgroundSyncSkipped(
          'no answer within ${deadline.inSeconds}s',
          uid: settings.allAccounts ? uid : null,
        ),
        requested: true,
        givenUp: true,
      );
    }
    final outcome = await _outcomeOf(info, storage, settings, account);
    fetched = outcome is BackgroundSyncDone && outcome.result is NotificationSyncResultSuccess;
    return (outcome: outcome, requested: true, givenUp: false);
  } finally {
    if (!fetched) {
      // Nothing came of this poll: the app's own sync may take the interval after all.
      await NotificationPollSlot.release(storage, uid, slot);
    }
  }
}

/// The outcome of a finished fetch of [account], against the settings read again now (see [backgroundSyncTick]);
/// [settings] are the ones the tick started with.
///
/// With every account announced (as the settings are now) a fetch is announced whichever account is in use: its
/// notification names its account and a tap opens it as that account. Otherwise only the account in use is, as before.
Future<BackgroundSyncOutcome> _outcomeOf(
  Either<AppException, NotificationSyncAllInfo> info,
  StorageProvider storage,
  BackgroundSyncSettings settings,
  UserLoginInfo account,
) async {
  final uid = account.uid!;
  final tagged = settings.allAccounts ? uid : null;
  final after = await readBackgroundSyncSettings(storage);
  if (!after.enabled) {
    return const BackgroundSyncDisabled();
  }
  if (!after.allAccounts && after.loginUid != uid) {
    return BackgroundSyncStale(
      uid == settings.loginUid ? 'account switched during the fetch' : 'all accounts switched off during the fetch',
      uid: tagged,
    );
  }
  if (after.intervalSeconds <= 0) {
    return BackgroundSyncStale('auto sync set to never during the fetch', uid: tagged);
  }
  return switch (info) {
    Left(:final value) => BackgroundSyncSkipped('sync failed: $value', uid: tagged),
    Right(:final value) => BackgroundSyncDone(
      uid: uid,
      username: account.username,
      named: after.allAccounts,
      result:
          value.finished.where((e) => e.$1.uid == uid).lastOrNull?.$2 ?? const NotificationSyncResultFailed('no result'),
    ),
  };
}
