part of 'models.dart';

/// One record in the current user's favorites list, a thread or a forum.
///
/// Comes from `home.php?mod=space&do=favorite&type=TYPE`, one `<li id="fav_FAVID">` per record, or, since plugin
/// 2.5.0, one row of `items` of the structured answer (`schema: 8`: [FavoriteThread.fromApi],
/// [FavoriteForum.fromApi]).
@MappableClass()
sealed class FavoriteItem with FavoriteItemMappable {
  /// Constructor.
  const FavoriteItem({required this.favid, required this.title, required this.url, this.time, this.description});

  /// Id of the favorite record, required when removing it.
  final String favid;

  /// Title of the thread or name of the forum.
  final String title;

  /// Absolute url of the target.
  final String url;

  /// Time the record was added to favorites.
  final DateTime? time;

  /// Optional note written when adding the favorite.
  final String? description;

  /// Kind of the record.
  FavoriteType get type;

  /// Id of the target: tid of a thread, fid of a forum.
  String get targetId;
}

/// Whether the row [row] of a structured favorites answer is a record of [kind] (`thread`, `forum`): the plugin names
/// the kind of every row (and the id type, `tid` / `fid`, which tells the same when the kind is missing). The page of
/// one type lists that type only, as the page parsers take only the rows linking the thread or the forum.
bool _favoriteRowIsKind(Map<String, dynamic> row, String kind, String idType) {
  final rowKind = tsdmAppText(row['kind']);
  return rowKind.isNotEmpty ? rowKind == kind : tsdmAppText(row['idtype']) == idType;
}

/// The absolute url of the target of the row [row]: the url the forum built (`url`), [fallback] when it names none.
String _favoriteRowUrl(Map<String, dynamic> row, String fallback) {
  final url = tsdmAppText(row['url']).trim();
  return (url.isEmpty ? fallback : url).prependHost();
}

/// The note of the row [row] (`description`, plain text with its line breaks), null when none was written.
String? _favoriteRowDescription(Map<String, dynamic> row) {
  final description = tsdmAppText(row['description']).trim();
  return description.isEmpty ? null : description;
}
