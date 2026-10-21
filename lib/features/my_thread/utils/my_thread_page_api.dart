import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

/// The structured "my threads" answer in [data]: a JSON answer of the forum's app API that carries a
/// `home.php?mod=space&do=thread` page (the threads, the replies, the comments, the drafts of an account) as fields
/// (plugin 2.4.0, `type: mythread`, `schema` 9 or later), or the forum's own message of such a plugin (a guest:
/// `ok` 0, `error: message`, with `login` telling the two apart). Null when the answer has to be read from its
/// `document` as before: a web page, an older plugin's answer (no `schema`, no `login`), a failed build.
///
/// The lists are then built by [myThreadsFromApi] (the draft box by `draftPageFromApi`); the `document` of the
/// answer, when there is one, is never parsed.
Map<String, dynamic>? myThreadApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 9;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'mythread' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// The account a structured answer [json] ([myThreadApiAnswerOf]) was served to: its `uid`, null for a guest (0)
/// and for the forum's message, which names none. The draft box checks it as it checks the page's `discuz_uid` on
/// the document path. The account whose list it is (`owner.uid`, the viewer unless the page was asked with `uid=`)
/// is [myThreadApiOwnerUid].
int? myThreadApiViewerUid(Map<String, dynamic> json) {
  final uid = json['ok'] == 1 ? tsdmAppInt(json['uid']) : 0;
  return uid > 0 ? uid : null;
}

/// The account whose list a structured answer [json] (`ok` 1) is (`owner.uid`), null when the answer names none.
int? myThreadApiOwnerUid(Map<String, dynamic> json) {
  final uid = tsdmAppInt(tsdmAppMap(json['owner'])['uid']);
  return uid > 0 ? uid : null;
}

/// The thread list and the next page url of a structured answer [json] ([myThreadApiAnswerOf]) of the page [url].
///
/// The same list the web page gives through `MyThread.fromTr` (and `MyThread.buildReplyListFromTr` for the
/// replies): the rows of the page as [MyThread.fromApi] builds them, one row per reply on the reply page (`kind`
/// `reply`: `pid`, its text in `summary`, "......" when it has none; a row without a thread or a subject dropped, as
/// the page parser drops a malformed row, [tsdmAppIsThreadRow]), with the dates in the forum's wall clock
/// (`timeoffset`), and the url of the next page when the forum has one (`has_next`: the page's "下一页" link; the
/// page paginates without a total, `pages` is 0). The forum's message (`ok` 0: a guest) is an empty
/// list, as the web page of the message parsed to one.
(List<MyThread>, String? nextPageUrl) myThreadsFromApi(Map<String, dynamic> json, String url) {
  if (json['ok'] != 1) {
    talker.info('my thread page: the forum answered a message: ${json['message']}');
    return (const [], null);
  }
  final timeOffset = tsdmAppTimeOffset(json);
  final reply = json['kind'] == 'reply';
  final threads = tsdmAppList(
    json['threads'],
  ).where(tsdmAppIsThreadRow).map((e) => MyThread.fromApi(e, timeOffset: timeOffset, reply: reply)).toList();
  final page = tsdmAppInt(json['page']);
  final nextPageUrl = tsdmAppInt(json['has_next']) == 1 && page > 0 ? tsdmAppListPageUrl(url, page + 1) : null;
  return (threads, nextPageUrl);
}
