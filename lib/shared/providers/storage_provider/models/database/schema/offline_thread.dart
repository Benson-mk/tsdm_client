part of 'schema.dart';

/// Table of the thread pages saved for reading without network ("離線保存看過的帖子").
///
/// One row per page an account loaded: the answer of the forum exactly as it came for that account (the JSON answer of
/// the app API, or the web page), so it is built again by the same code when the network is gone. Rows of one account
/// are never shown to another account or to a guest: [uid] is part of every key. Only written while the setting is on,
/// removed with the account, and the least recently used threads go first once more than the chosen number of threads
/// are saved.
@DataClassName('OfflineThreadEntity')
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

  /// The answer of the forum as it came.
  TextColumn get body => text()();

  /// Size of [body] in bytes (UTF-8).
  IntColumn get size => integer()();

  /// When the page was loaded from the forum, shown on the offline banner.
  DateTimeColumn get savedAt => dateTime()();

  /// When the page was last loaded or read offline, in milliseconds since epoch, for evicting the least recently used
  /// threads (a date time column only keeps seconds: pages opened within one second would tie).
  IntColumn get lastUsedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {uid, tid, page, orderType, authorId};
}
