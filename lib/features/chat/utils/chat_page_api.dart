import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/features/chat/utils/parse_chat.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

/// The structured conversation answer in [data]: a JSON answer of the forum's app API that carries a private message
/// conversation page (`home.php?mod=space&do=pm&subop=view&touid=…`, or `plid=…`) as fields (plugin 2.5.0,
/// `type: pm`, `schema` 11 or later), or the forum's own message of such a plugin (a guest, the private messages
/// switched off: `ok` 0, `error: message`, with `login` telling the two apart). Null when the answer has to be read
/// from its `document` as before: a web page, an older plugin's answer (no `schema`, no `login`), a failed build, and
/// the private message list page, which the plugin keeps answering without a `schema` (the app reads the list from
/// `pmlist`).
///
/// The conversation is then built by [chatHistoryFromApi]; the `document` of the answer, when there is one, is never
/// parsed. The chat dialog (`spacecp&ac=pm&op=showmsg`, an AJAX answer) is not a page of the JSON mode and keeps its
/// own path.
Map<String, dynamic>? chatApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 11;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'pm' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// The conversation of a structured answer [json] ([chatApiAnswerOf]), the same [ChatHistoryInfo] the web page gives
/// through [parseChatHistory]: the other member (`tousername`; a group conversation names its `subject` instead),
/// the count of messages the reader can see (`count`, the page's "共有 N 条"), the messages of the page as
/// [ChatMessage.fromApi] builds them, newest first as the page parser orders them (the forum lists the page oldest
/// first), and the reply form (`reply`: its `action`, the `pmid` of the first message of the page, the member the
/// forum reads from `topmuid`; with the `formhash` of the answer), as [ChatHistorySendTarget] takes it from the
/// page's form. No form when there is no conversation yet (`reply` null, `count` 0), as the page prints none.
///
/// The forum serves the LAST page when no `page` is asked, as the web page does: the older messages are on
/// `page - 1` (`previousPage`), a next page only when the forum says so (`has_next`). The forum's message (`ok` 0: a
/// guest, the private messages switched off) is null, as the message page parsed to (no conversation on it).
ChatHistoryInfo? chatHistoryFromApi(Map<String, dynamic> json) {
  if (json['ok'] != 1) {
    talker.info('chat history: the forum answered a message: ${json['message']}');
    return null;
  }
  final peer = tsdmAppText(json['tousername']).trim();
  final username = peer.isNotEmpty ? peer : tsdmAppText(json['subject']).trim();
  final page = tsdmAppInt(json['page']);
  final timeOffset = tsdmAppTimeOffset(json);
  final messages = tsdmAppList(
    json['messages'],
  ).map((e) => ChatMessage.fromApi(e, timeOffset: timeOffset)).nonNulls.toList().reversed.toList();

  ChatHistorySendTarget? target;
  final reply = json['reply'];
  if (reply is Map<String, dynamic>) {
    final action = tsdmAppText(reply['action']).trim();
    final pmid = tsdmAppInt(reply['pmid']);
    final topmuid = tsdmAppInt(reply['topmuid']);
    final formHash = tsdmAppText(json['formhash']).trim();
    if (action.isNotEmpty && pmid > 0 && formHash.isNotEmpty) {
      // Sent as the page's form is: the action with `inajax=1` so the forum answers the result alone, and the peer
      // the Discuz X5 form carries in its hidden `topmuid` (read from the query by the forum).
      final targetUrl = '${action.prependHost()}&inajax=1';
      target = ChatHistorySendTarget(
        targetUrl: topmuid > 0 && !targetUrl.contains('topmuid=') ? '$targetUrl&topmuid=$topmuid' : targetUrl,
        pmid: '$pmid',
        formHash: formHash,
      );
    } else {
      talker.error(
        'failed to build send target in chat history answer: action=$action, pmid=$pmid, formhash=$formHash',
      );
    }
  }

  return (
    username: username,
    messageCount: tsdmAppInt(json['count']),
    previousPage: page > 1 ? page - 1 : null,
    nextPage: tsdmAppInt(json['has_next']) == 1 && page > 0 ? page + 1 : null,
    sendTarget: target,
    messages: messages,
  );
}
