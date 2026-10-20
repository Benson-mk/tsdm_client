import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/search/utils/search_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

/// The structured guide answer in [data]: a JSON answer of the forum's app API that carries a guide page
/// (`forum.php?mod=guide&view=…`) as fields (plugin 2.4.0, `type: guide`, `schema` 7 or later), or the forum's own
/// message of such a plugin (the guide switched off, a guest asked for "my" threads: `ok` 0, `error: message`, with
/// `login` telling the two apart). Null when the answer has to be read from its `document` as before: a web page,
/// an older plugin's answer (no `schema`, no `login`), a failed build.
///
/// The lists are then built by [latestThreadsFromApi] (the guide index, `view=index`, by `guideModulesFromApi` of the
/// homepage); the `document` of the answer, when there is one, is never parsed.
Map<String, dynamic>? guideApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 7;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'guide' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// The structured answer in [data] of a page the latest thread page lists: a guide list ([guideApiAnswerOf]) or the
/// search results of 查看新帖 (`search.php?mod=forum&srchfrom=…`, [searchApiAnswerOf]), which share one row shape.
Map<String, dynamic>? latestThreadApiAnswerOf(Object? data) => guideApiAnswerOf(data) ?? searchApiAnswerOf(data);

/// The thread list and the next page url of a structured answer [json] ([latestThreadApiAnswerOf]) of the list page
/// [url].
///
/// The same list the web page gives: the rows of the page as [LatestThread.fromApi] builds them (`threads`; the
/// guide index, `view=index`, lists its rows in `modules` and none here), and the url of the next page when the
/// forum has one (`has_next`: the page's "下一页" link): the guide page asked with the next `page`, a search its own
/// paging link (`searchid`). The forum's message (`ok` 0: the guide switched off, a guest asked for "my" threads)
/// is an empty list, as the web page of the message parsed to one.
(List<LatestThread>, String? nextPageUrl) latestThreadsFromApi(Map<String, dynamic> json, String url) {
  if (json['ok'] != 1) {
    talker.info('latest thread page: the forum answered a message: ${json['message']}');
    return (const [], null);
  }
  final threads = _list(json['threads']).map(LatestThread.fromApi).toList();
  final page = _int(json['page']);
  final hasNext = _int(json['has_next']) == 1 && page > 0;
  final String? nextPageUrl;
  if (!hasNext) {
    nextPageUrl = null;
  } else if (json['type'] == 'search') {
    nextPageUrl = searchResultPageUrl(json, page + 1);
  } else {
    nextPageUrl = tsdmAppListPageUrl(url, page + 1);
  }
  return (threads, nextPageUrl);
}

int _int(Object? value) => switch (value) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];
