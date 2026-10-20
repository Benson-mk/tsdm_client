part of 'models.dart';

/// A thread record in the current user's favorites list.
///
/// Comes from `home.php?mod=space&do=favorite&type=thread`, one `<li id="fav_FAVID">` per record.
@MappableClass()
final class FavoriteThread extends FavoriteItem with FavoriteThreadMappable {
  /// Constructor.
  const FavoriteThread({
    required super.favid,
    required this.tid,
    required super.title,
    required super.url,
    super.time,
    super.description,
  });

  /// The record of a row [row] of the structured favorites answer (plugin 2.5.0, `schema: 8`, `items[]`): the record
  /// id (`favid`), the thread (`id`, `idtype` tid), its title (plain text), the url the forum built, the time the
  /// record was added (`dateline`) and the note. Null for a row that is not a thread, or names no record or thread,
  /// as the page parser skips a row without the record id or the thread link.
  static FavoriteThread? fromApi(Map<String, dynamic> row) {
    final favid = tsdmAppInt(row['favid']);
    final tid = tsdmAppInt(row['id']);
    if (favid <= 0 || tid <= 0 || !_favoriteRowIsKind(row, 'thread', 'tid')) {
      return null;
    }
    return FavoriteThread(
      favid: '$favid',
      tid: '$tid',
      title: tsdmAppText(row['title']).trim(),
      url: _favoriteRowUrl(row, 'forum.php?mod=viewthread&tid=$tid'),
      time: tsdmAppTime(row['dateline']),
      description: _favoriteRowDescription(row),
    );
  }

  /// Thread id.
  final String tid;

  @override
  FavoriteType get type => FavoriteType.thread;

  @override
  String get targetId => tid;
}
