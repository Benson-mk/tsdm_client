import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

/// The structured favorites answer in [data]: a JSON answer of the forum's app API that carries a favorites page
/// (`home.php?mod=space&do=favorite&type=…`) as fields (plugin 2.5.0, `type: favorite`, `schema` 8 or later), or the
/// forum's own message of such a plugin (a guest, the favorites switched off: `ok` 0, `error: message`, with `login`
/// telling the two apart). Null when the answer has to be read from its `document` as before: a web page, an older
/// plugin's answer (no `schema`, no `login`), a failed build.
///
/// The list is then built by [favoriteThreadsFromApi], [favoriteForumsFromApi] or [favoriteListPageOfTypeFromApi];
/// the `document` of the answer, when there is one, is never parsed.
Map<String, dynamic>? favoriteApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 8;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'favorite' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// The thread favorites of a structured answer [json] ([favoriteApiAnswerOf]) of the page [url], the same
/// [FavoriteListPage] the web page gives through `parseFavoriteListPage`: the rows as [FavoriteThread.fromApi]
/// builds them (a row that is not a thread record dropped, as the page parser takes only the rows linking a
/// thread), and the url of the next page when the forum has one (`has_next`: the page's "下一页" link, the page
/// asked with the next `page`). The forum's message (`ok` 0) is an empty list, as the message page parsed to, with
/// [FavoriteListPage.needLogin] when it asks to log in ([tsdmAppMessageAsksLogin]). An empty list is a page (`count`
/// 0, `items []`), as the page prints "您还没有添加任何收藏" then, not a message.
FavoriteListPage<FavoriteThread> favoriteThreadsFromApi(Map<String, dynamic> json, String url) =>
    _listPage(json, url, FavoriteThread.fromApi);

/// The forum favorites of a structured answer [json] ([favoriteApiAnswerOf]) of the page [url], as
/// [favoriteThreadsFromApi] builds the threads: the rows as [FavoriteForum.fromApi] builds them.
FavoriteListPage<FavoriteForum> favoriteForumsFromApi(Map<String, dynamic> json, String url) =>
    _listPage(json, url, FavoriteForum.fromApi);

/// The favorites of [type] of a structured answer [json] ([favoriteApiAnswerOf]) of the page [url]:
/// [favoriteThreadsFromApi] or [favoriteForumsFromApi].
FavoriteListPage<FavoriteItem> favoriteListPageOfTypeFromApi(
  Map<String, dynamic> json,
  FavoriteType type,
  String url,
) => switch (type) {
  FavoriteType.thread => favoriteThreadsFromApi(json, url),
  FavoriteType.forum => favoriteForumsFromApi(json, url),
};

FavoriteListPage<T> _listPage<T extends FavoriteItem>(
  Map<String, dynamic> json,
  String url,
  T? Function(Map<String, dynamic> row) item,
) {
  if (json['ok'] != 1) {
    talker.info('favorites page: the forum answered a message: ${json['message']}');
    return FavoriteListPage(items: const [], needLogin: tsdmAppMessageAsksLogin(json));
  }
  final items = tsdmAppList(json['items']).map(item).whereType<T>().toList();
  final page = tsdmAppInt(json['page']);
  final nextPageUrl = tsdmAppInt(json['has_next']) == 1 && page > 0 ? tsdmAppListPageUrl(url, page + 1) : null;
  return FavoriteListPage(items: items, nextPageUrl: nextPageUrl);
}
