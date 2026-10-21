import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Shares the notification polling of an account between the in-app auto sync and the Android background service.
///
/// Both run on the same interval in the same process, each with its own timer. Fetching twice a minute costs the
/// forum twice the requests, and the app API answers two calls within its interval with HTTP 429 (GitHub #173). The
/// time of the last poll is kept in the shared database: whoever comes within half an interval of the other one
/// skips, so each interval is polled once whatever the two timers' phase. What one poller fetches reaches the other:
/// the service's rows are reloaded by the app, the app's rows are found by the service's next fetch.
///
/// Every account has its own poll: with every logged-in account polled (`backgroundSyncAllAccounts`) the other
/// accounts are shared the same way between the app and the service, and the sync of all accounts the user asks for
/// takes each account's poll too ([takeForManualSync]).
///
/// The poll only keeps one account from being asked twice within the window; the pause between two accounts is each
/// path's own (the background tick, the in-app round of the other accounts, the sync of all accounts): two paths may
/// ask the forum at the same moment for two different accounts, which the plugin's limit (per action and account)
/// does not mind. A sync of all accounts started while an automatic round fetches an account finds that account's
/// poll taken and shows what is stored, possibly from before the round's answer arrived; the round's notification
/// still announces it.
abstract final class NotificationPollSlot {
  /// Settings name of the last poll time of [uid], in milliseconds since epoch. Removed with the account.
  static String key(int uid) => StorageProvider.notificationPolledAtKey(uid);

  /// Settings name of the time of the last poll of [uid] taken by the sync of all accounts the user asks for
  /// ([takeForManualSync]): equal to [key] while that poll is the last one. Removed with the account.
  static String manualKey(int uid) => StorageProvider.notificationPolledManuallyAtKey(uid);

  /// Longest a poll of the auto sync is reused by the sync of all accounts the user asks for.
  static const manualReuseLimit = Duration(seconds: 30);

  /// Take the poll of [uid] for an [interval] poller at [now] (default: the current time).
  ///
  /// The poll taken (its time, to [release] it), or null when another poll started less than half an [interval]
  /// before: this one is not needed. A time in the future (the clock was turned back) does not block.
  static Future<int?> take(StorageProvider storage, int uid, Duration interval, {DateTime? now}) async {
    final time = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final last = await storage.getInt(key(uid));
    if (last != null && time >= last && time - last <= interval.inMilliseconds ~/ 2) {
      return null;
    }
    await storage.saveInt(key(uid), time);
    return time;
  }

  /// Take the poll of [uid] for the sync of all accounts the user asks for, auto sync every [interval], at [now]
  /// (default: the current time).
  ///
  /// Null when the in-app auto sync or the background service polled the account within half an [interval], at most
  /// [manualReuseLimit] ago: what it stored is fresh, the forum is not asked again (it answers a second call within
  /// its interval with 429). A poll of an earlier sync of all accounts is never reused: asked again by the user, the
  /// forum is asked again. Otherwise the poll is taken, its time returned and recorded as this kind's ([manualKey]);
  /// the auto sync skips the account within half an interval of it, as after any poll. Give it back with [release].
  static Future<int?> takeForManualSync(StorageProvider storage, int uid, Duration interval, {DateTime? now}) async {
    final time = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final last = await storage.getInt(key(uid));
    final manual = await storage.getInt(manualKey(uid));
    final half = interval.inMilliseconds ~/ 2;
    final reuse = half < manualReuseLimit.inMilliseconds ? half : manualReuseLimit.inMilliseconds;
    if (last != null && last != 0 && last != manual && time >= last && time - last <= reuse) {
      return null;
    }
    await storage.saveInt(key(uid), time);
    await storage.saveInt(manualKey(uid), time);
    return time;
  }

  /// Give back the poll taken as [slot] when it brought nothing (the forum was not reached): the other poller may
  /// take the interval after all. A poll taken since is left alone.
  static Future<void> release(StorageProvider storage, int uid, int slot) async {
    if (await storage.getInt(key(uid)) == slot) {
      await storage.saveInt(key(uid), 0);
    }
  }
}
