import 'dart:convert';

import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/card/post_card/post_medal_menu_info.dart';
import 'package:universal_html/parsing.dart';

/// The structured thread page answer in [data]: a JSON answer of the forum's app API that carries every field the app
/// reads (plugin 2.1.0, `schema` 3 or later, `type: thread`: other pages have their own schemas), or the forum's own
/// message of such a plugin (no permission, please log in, no such thread: `ok` 0, `error: message`, with `login`
/// telling the two apart). Null when the answer has to be read from its `document` as before: a web page, an older
/// plugin's answer (no `schema`, no `login`), the antitheft challenge or the thread cache a guest is served
/// (`error: unknown`), a failed build.
///
/// The page is then built by [threadPageFromApi]; the `document` of the answer, when there is one, is never parsed.
Map<String, dynamic>? threadApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 3;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'thread' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// Build the thread page from a structured answer [json] of the forum's app API ([threadApiAnswerOf]), asked for
/// page [pageNumber].
///
/// The same [ThreadPageInfo] the web page gives through [parseThreadDocument], from the fields instead of the html:
///
/// * `thread` gives the id (null when the answer does not name it, so the page keeps the thread it asked for), the
///   title, the forum, the counts, the soft close (the lock beside the title), the draft mark, the latest moderation
///   sentence (`modact`, the page's `div.modact`) and the type (`typeid` with `typename`, the `[type]` beside the
///   title; none when the thread has no type);
/// * `forum.name` is the forum's name, `nav` the breadcrumbs from the group down to the forum of the thread (the
///   group linked as `forum.php?gid=`, a forum as `forum.php?mod=forumdisplay&fid=`), the thread itself not among
///   them, as the page's breadcrumb parser leaves them;
/// * `page` / `pages` are the pagination the forum printed (`page` clamped to the last page as the forum does when
///   asked past it; the `pages` of the forum's own order, which a reversed or author-only request keeps);
/// * `reply.allowed` (the thread takes a reply), `reply.fastpost` (the fast reply form is printed) and
///   `reply.fastpost_allowed` (the form has its textarea: a newbie, an account without avatar… have `allowed` 1 but
///   no textarea) tell a member whether the thread is closed (`threadClosed`), as the page parser reads the form and
///   its closed hint; a guest's page is never closed, as the web page tells a guest to log in instead;
/// * `reply` with the answer's `formhash` is the fast reply form (`replyParameters`), none when the forum prints no
///   form (`fastpost` 0);
/// * `posts` are the floors in the forum's order, hot and sticky replies included ([Post.fromApi]), with the
///   answer's `uid` as the account they were served to; the placeholder of a deleted floor of a rush thread
///   (`deleted` 1) is left out, as the page parser leaves it out;
/// * `menus_html` are the medal menus of the page, parsed as the page's (`PostMedalMenuItem`).
///
/// The forum's message (`ok` 0): `login` 1 is the login prompt of a guest (`needLogin`), 0 a member without
/// permission (`havePermission` false, the message text as the denied message, as the page's `#messagetext p`);
/// such a page names no thread and has no reply form, as the web page has none.
ThreadPageInfo threadPageFromApi(Map<String, dynamic> json, int pageNumber) {
  if (json['ok'] != 1) {
    final needLogin = json['login'] == 1;
    return ThreadPageInfo(
      tid: null,
      title: null,
      fid: null,
      forumName: null,
      currentPage: pageNumber,
      totalPages: pageNumber,
      havePermission: needLogin,
      permissionDeniedMessage: needLogin
          ? null
          : parseHtmlDocument('<p>${htmlEscape.convert(_text(json['message']))}</p>').querySelector('p'),
      needLogin: needLogin,
      threadSoftClosed: false,
      // No reply form on a message page, as on the web page.
      threadClosed: true,
      postList: const [],
      replyParameters: null,
      threadType: null,
      isDraft: false,
      latestModAct: null,
      breadcrumbs: const [],
      postMedals: const [],
      viewCount: null,
      replyCount: null,
    );
  }

  final thread = _map(json['thread']);
  final forum = _map(json['forum']);
  final reply = _map(json['reply']);
  final uid = _int(json['uid']);
  // A thread id the answer does not name (or names badly) is null, so the page keeps the thread it asked for.
  final tidValue = _int(thread['tid']);
  final tid = tidValue > 0 ? '$tidValue' : null;
  final fidValue = _int(thread['fid']);
  final fid = fidValue > 0 ? fidValue : null;
  final currentPage = json['page'] is num ? _int(json['page']) : pageNumber;
  final totalPages = json['pages'] is num ? _int(json['pages']) : pageNumber;
  final draft = _int(thread['draft']) == 1;
  final pay = thread['pay'] is Map<String, dynamic> ? _map(thread['pay']) : null;

  // The placeholder a rush thread prints for a deleted floor (`deleted` 1: "无效楼层，该帖已经被删除", no author, no
  // content) is left out, as the page parser leaves out a floor without an author.
  final postList = _list(json['posts'])
      .where((p) => _int(p['deleted']) != 1)
      .map(
        (p) => Post.fromApi(
          p,
          tid: tid ?? '',
          fid: fid ?? 0,
          viewerUid: uid,
          page: currentPage,
          pay: pay,
          draft: draft,
        ),
      )
      .toList();

  final typeId = _int(thread['typeid']);
  final typeName = _text(thread['typename']);
  final threadType = typeId > 0 && typeName.isNotEmpty ? FilterType(name: typeName, typeID: '$typeId') : null;

  final formHash = _text(json['formhash']);
  final replyParameters = _int(reply['fastpost']) == 1 && formHash.isNotEmpty && tid != null && fid != null
      ? ReplyParameters(
          fid: '$fid',
          tid: tid,
          postTime: reply['posttime'] is String ? _text(reply['posttime']) : null,
          formHash: formHash,
          subject: _text(reply['subject']),
        )
      : null;

  final breadcrumbs = _list(json['nav'])
      .map(
        (e) => ThreadBreadcrumb(
          description: _text(e['name']),
          link: Uri.parse(
            _text(e['type']) == 'group'
                ? '$baseUrl/forum.php?gid=${_int(e['fid'])}'
                : '$baseUrl/forum.php?mod=forumdisplay&fid=${_int(e['fid'])}',
          ),
        ),
      )
      .toList();

  final menus = json['menus_html'] is List ? (json['menus_html'] as List).whereType<String>().join() : '';
  final postMedals = menus.isEmpty
      ? const <PostMedalMenuItem>[]
      : parseHtmlDocument(menus)
            .querySelectorAll(r'div[id^="md_"][id$="_menu"]')
            .map(PostMedalMenuItem.fromDiv)
            .whereType<PostMedalMenuItem>()
            .toList();

  final modAct = _text(thread['modact']);

  return ThreadPageInfo(
    tid: tid,
    title: _text(thread['subject']),
    fid: fid,
    forumName: _text(forum['name']),
    currentPage: currentPage,
    totalPages: totalPages,
    havePermission: true,
    permissionDeniedMessage: null,
    needLogin: false,
    threadSoftClosed: _int(thread['soft_closed']) == 1,
    // Closed for a member when the forum takes no reply, prints no fast reply form, or a form without its textarea
    // (a newbie, an account without avatar…), as the page parser reads the form. A guest is told to log in instead
    // of a closed thread on the web page: not closed until logged in.
    threadClosed:
        uid > 0 &&
        (_int(reply['allowed']) == 0 || _int(reply['fastpost']) == 0 || _int(reply['fastpost_allowed']) == 0),
    postList: postList,
    replyParameters: replyParameters,
    threadType: threadType,
    isDraft: draft,
    latestModAct: modAct.isEmpty ? null : modAct,
    breadcrumbs: breadcrumbs,
    postMedals: postMedals,
    viewCount: _int(thread['views']),
    replyCount: _int(thread['replies']),
  );
}

/// The account a structured answer [json] ([threadApiAnswerOf]) was served to: its `uid`, null for a guest (0) and
/// for the forum's message, which names none. The readers bound to one account (a draft confirmed, a poll verified,
/// a report prepared) check it as they check the page's `discuz_uid` on the document path.
int? threadApiViewerUid(Map<String, dynamic> json) {
  final uid = _int(json['uid']);
  return uid > 0 ? uid : null;
}

int _int(Object? value) => switch (value) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};

String _text(Object? value) => value is String ? value : '';

Map<String, dynamic> _map(Object? value) => value is Map<String, dynamic> ? value : const {};

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];
