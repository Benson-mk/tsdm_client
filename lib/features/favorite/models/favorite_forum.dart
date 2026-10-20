part of 'models.dart';

/// A forum record in the current user's favorites list.
///
/// Comes from `home.php?mod=space&do=favorite&type=forum`, one `<li id="fav_FAVID">` per record.
@MappableClass()
final class FavoriteForum extends FavoriteItem with FavoriteForumMappable {
  /// Constructor.
  const FavoriteForum({
    required super.favid,
    required this.fid,
    required super.title,
    required super.url,
    super.time,
    super.description,
  });

  /// The record of a row [row] of the structured favorites answer (plugin 2.5.0, `schema: 8`, `items[]`), as
  /// [FavoriteThread.fromApi] reads a thread row: null for a row that is not a forum, or names no record or forum.
  static FavoriteForum? fromApi(Map<String, dynamic> row) {
    final favid = tsdmAppInt(row['favid']);
    final fid = tsdmAppInt(row['id']);
    if (favid <= 0 || fid <= 0 || !_favoriteRowIsKind(row, 'forum', 'fid')) {
      return null;
    }
    return FavoriteForum(
      favid: '$favid',
      fid: '$fid',
      title: tsdmAppText(row['title']).trim(),
      url: _favoriteRowUrl(row, 'forum.php?mod=forumdisplay&fid=$fid'),
      time: tsdmAppTime(row['dateline']),
      description: _favoriteRowDescription(row),
    );
  }

  /// Forum id.
  final String fid;

  @override
  FavoriteType get type => FavoriteType.forum;

  @override
  String get targetId => fid;
}
