part of 'schema.dart';

/// Table of the thread pages saved for reading without network ("離線保存看過的帖子").
///
/// One row per page an account loaded: the answer of the forum exactly as it came for that account (the JSON answer of
/// the app API, or the web page), so it is built again by the same code when the network is gone. Rows of one account
/// are never shown to another account or to a guest: [uid] is part of every key. Only written while the setting is on,
/// removed with the account, and the least recently used pages and threads go first beyond the limits.
///
/// [body] is the last column and the index holds everything else the eviction and the size read: neither reads a body.
@DataClassName('OfflineThreadEntity')
@TableIndex(name: 'offline_thread_recent', columns: {#uid, #tid, #lastUsedAt, #size})
class OfflineThread extends Table {
  /// The account the page was served to, part of [primaryKey].
  IntColumn get uid => integer()();

  /// Thread id, part of [primaryKey].
  IntColumn get tid => integer()();

  /// Page number asked for, part of [primaryKey].
  IntColumn get page => integer()();

  /// `ordertype` asked for (1 newest first, 2 oldest first), 0 when none; part of [primaryKey].
  IntColumn get orderType => integer()();

  /// `authorid` asked for (only the floors of one user), 0 when none; part of [primaryKey].
  IntColumn get authorId => integer()();

  /// Size of [body] in bytes (UTF-8).
  IntColumn get size => integer()();

  /// When the page was loaded from the forum, shown on the offline banner.
  DateTimeColumn get savedAt => dateTime()();

  /// When the page was last loaded or read offline, in milliseconds since epoch, for evicting the least recently used
  /// pages and threads (a date time column only keeps seconds: pages opened within one second would tie).
  IntColumn get lastUsedAt => integer()();

  /// The answer of the forum as it came. Last: the other columns of a row are read without it.
  TextColumn get body => text()();

  @override
  Set<Column<Object>> get primaryKey => {uid, tid, page, orderType, authorId};
}
