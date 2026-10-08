import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Shares the notification polling of an account between the in-app auto sync and the Android background service.
///
/// Both run on the same interval in the same process, each with its own timer. Fetching twice a minute costs the
/// forum twice the requests, and the app API answers two calls within its interval with HTTP 429 (GitHub #173). The
/// time of the last poll is kept in the shared database: whoever comes within half an interval of the other one
/// skips, so each interval is polled once whatever the two timers' phase. What one poller fetches reaches the other:
/// the service's rows are reloaded by the app, the app's rows are found by the service's next fetch.
abstract final class NotificationPollSlot {
  /// Settings name of the last poll time of [uid], in milliseconds since epoch.
  static String key(int uid) => 'notificationPolledAt.$uid';

  /// Take the poll of [uid] for an [interval] poller at [now] (default: the current time).
  ///
  /// The poll taken (its time, to [release] it), or null when another poll started less than half an [interval]
  /// before: this one is not needed. A time in the future (the clock was turned back) does not block.
  static Future<int?> take(StorageProvider storage, int uid, Duration interval, {DateTime? now}) async {
    final time = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final last = await storage.getInt(key(uid));
    if (last != null && time >= last && time - last < interval.inMilliseconds ~/ 2) {
      return null;
    }
    await storage.saveInt(key(uid), time);
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
