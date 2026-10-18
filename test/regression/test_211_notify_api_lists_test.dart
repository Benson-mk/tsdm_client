/// The notification fetch reads the lists of the forum's app API (plugin 1.9.0) instead of the web pages.
///
/// `notify` always carried the whole notices and the unread broadcast messages, yet the app fetched the notice page,
/// the private message page and the broadcast message page whenever it said something arrived. Since plugin 1.9.0
/// (its `notify` answer carries the form hash `seen` needs):
///
/// * The notices come from `notify`, the same as the notice page shows them (absolute urls, the ignore target).
/// * The conversations come from `pmlist` (the list of the private message page, sent and read ones too), asked by
///   a poll only when a conversation changed; the private message page when `pmlist` does not answer.
/// * The broadcast messages come from `notify` for a poll (the unread ones, all a poll keeps), from the broadcast
///   message page for the first fetch and a refresh (the read ones too).
/// * Opening the notice page marked the notices read, opening the private message page cleared the forum's "new"
///   prompt: the fetch posts `seen` for that, and a failed `seen` changes nothing else.
///
/// An older plugin, no plugin, or a `notify` refused as too soon: the three pages as before.
///
/// Also: the private message page prints the red dot `div.newpm_avt` in every row on Discuz! X5, the unread marker is
/// the row's class `newpm`.
///
/// Synthetic answers and names, except the notice and private message pages of `test/data`; no real account.
library;

import 'dart:convert';
import 'dart:io' show File, HttpDate;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// The forum clock: now, since the repository clamps `since` to three days ago.
final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// The bound a poll stored ten minutes ago: a whole minute, as `nextFetchBound` stores it.
final int _since = (_now - 600) - (_now - 600) % 60;

const _uid = 3000;
const _formhash = 'a1b2c3d4';

String _timeTextOf(DateTime t) =>
    '${t.year}-${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _timeOf(int seconds) => _timeTextOf(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));

/// A reply notice body as the forum stores it: relative links, raw `&`, a smiley.
String _replyNote(int pid) =>
    '<a href="home.php?mod=space&uid=3001">Peer</a> 回复了您的帖子 '
    '<a href="forum.php?mod=redirect&goto=findpost&ptid=5&pid=$pid" target="_blank">Synthetic thread</a> &nbsp; '
    '<img src="static/image/smiley/default/smile.gif" smilieid="1" border="0" alt="" /> '
    '<a href="forum.php?mod=redirect&goto=findpost&pid=$pid&ptid=5" target="_blank" class="lit">查看</a>';

/// A notice of `notify`.
Map<String, Object?> _notice(
  int id,
  int dateline, {
  bool unread = true,
  int authorId = 3001,
  String type = 'post',
  String? note,
}) => {
  'id': id,
  'new': unread ? 1 : 0,
  'type': type,
  'category': 1,
  'authorid': authorId,
  'author': authorId == 0 ? '' : 'Peer',
  'note': note ?? _replyNote(id),
  'text': 'Peer 回复了您的帖子 Synthetic thread',
  'dateline': dateline,
  'from_id': 5,
  'from_idtype': 'post',
  'from_num': 0,
};

/// A conversation row of `pmlist` (and of the `pms` of `notify`).
Map<String, Object?> _pm(
  int plid, {
  required int peer,
  required int at,
  bool unread = false,
  bool sentByMe = false,
  int type = 1,
  String text = 'hello',
  String? name,
}) => {
  'plid': plid,
  'new': unread ? 1 : 0,
  'type': type,
  'subject': '',
  'count': 2,
  'members': 2,
  'touid': peer,
  'tousername': name ?? 'Peer$peer',
  'lastauthorid': sentByMe ? _uid : peer,
  'lastauthor': sentByMe ? 'Alice' : 'Peer$peer',
  'lastsummary': text,
  'lastdateline': at,
};

/// An unread broadcast message of `notify`.
Map<String, Object?> _announce(int id, int dateline, String text) => {
  'id': id,
  'new': 1,
  'authorid': 1,
  'author': 'admin',
  'dateline': dateline,
  'message': '<b>$text</b>',
  'text': text,
};

/// A `notify` answer; [lists] false is a plugin before 1.9.0 (no version, no form hash).
Map<String, Object?> _notify({
  List<Map<String, Object?>> notices = const [],
  List<Map<String, Object?>> pms = const [],
  List<Map<String, Object?>> announces = const [],
  int pmLast = 0,
  bool lists = true,
  String formhash = _formhash,
  int? time,
}) => {
  'ok': 1,
  'api': 1,
  if (lists) 'version': '1.9.0',
  'time': time ?? _now,
  'uid': _uid,
  if (lists) 'formhash': formhash,
  'counts': {
    'notice': notices.where((e) => e['new'] == 1).length,
    'pm': pms.length,
    'announce': announces.length,
  },
  'pm_last': pmLast,
  'notices': notices,
  'pms': pms,
  'announces': announces,
};

Map<String, Object?> _pmlist(List<Map<String, Object?>> pms, {int closed = 0}) => {
  'ok': 1,
  'api': 1,
  'time': _now,
  'uid': _uid,
  'closed': closed,
  'page': 1,
  'perpage': 20,
  'count': pms.length,
  'pms': pms,
};

/// A notice node as the notice page renders it (`template/default/home/space_notice.php`).
String _noticeNode(Map<String, Object?> n) {
  final id = n['id'];
  final author = n['authorid'];
  final avatar = author == 0
      ? '<img src="static/image/common/systempm.png" alt="systempm" />'
      : '<a href="home.php?mod=space&amp;uid=$author"><img data-src="./data/avatar/a.jpg" class="_avt user_avatar"></a>';
  const ignore = 'home.php?mod=spacecp&amp;ac=common&amp;op=ignore';
  final href = '$ignore&amp;authorid=$author&amp;type=${n['type']}&amp;handlekey=noticeignore';
  return '<dl class="cl "  notice="$id" id="notice_$id">\n<dd class="m avt mbn">\n$avatar\n</dd>\n<dt>\n'
      '<a class="d b" href="$href" id="a_note_$id" onclick="showWindow(\'noticeignore\', this.href, \'get\', 0);" '
      'title="屏蔽">屏蔽</a>\n<span class="xg1 xw0"><span title="${_timeOf(n['dateline']! as int)}">1&nbsp;分钟前</span>\n'
      '</span>\n</dt>\n<dd class="ntc_body" style="${n['new'] == 1 ? 'color:#000;font-weight:bold;' : ''}">\n'
      '${n['note']}\n</dd>\n\n\n</dl>\n';
}

String _noticePage(List<Map<String, Object?>> notices) =>
    '<html><body><div id="um"></div><div id="ct"><div class="mn"><div class="bm bw0"><div class="xld xlda">\n'
    '<div class="nts">${notices.map(_noticeNode).join()}</div></div></div></div></div></body></html>';

/// A conversation node as the private message page renders it (`template/default/home/space_pm.php`): the red dot
/// in every row, the class `newpm` on the unread ones.
String _pmNode(Map<String, Object?> pm) {
  final peer = pm['touid'];
  final plid = pm['plid'];
  final name = pm['tousername'];
  final who = pm['lastauthorid'] == _uid
      ? '<span class="xi2 xw1">您</span> 对 <a href="home.php?mod=space&amp;uid=$peer" target="_blank">$name</a> 说 :'
      : '<a href="home.php?mod=space&amp;uid=$peer" target="_blank" class="xw1">$name</a> 对 <span class="xi2">您</span> 说 :';
  return '<dl id="pmlist_$plid" class="bbda cur1 cl${pm['new'] == 1 ? ' newpm' : ''}">\n'
      '<dd class="m avt">\n<div class="newpm_avt" title="有未读消息"></div>\n'
      '<a href="home.php?mod=space&amp;uid=$peer" target="_blank"><img data-src="./data/avatar/a.jpg" class="_avt"></a>\n'
      '</dd>\n<dd class="ptm pm_c">\n<div class="o">\n'
      '<input type="checkbox" name="deletepm_deluid[]" id="a_delete_$plid" class="pc" value="$peer" />\n</div>\n'
      '$who<br />\n${pm['lastsummary']} &nbsp;  <br />\n'
      '<span class="xg1"><span title="${_timeOf(pm['lastdateline']! as int)}">1&nbsp;分钟前</span></span> &nbsp; \n'
      '<span class="pm_o y"><span class="xg1 z">共 2 条</span>\n'
      '<a href="home.php?mod=space&amp;do=pm&amp;subop=view&amp;touid=$peer#last" id="pmlist_${plid}_a">回复</a>\n'
      '</span>\n</dd>\n</dl>\n';
}

String _pmPage(List<Map<String, Object?>> pms) =>
    '<html><body><div id="um"></div><form id="deletepmform"><div class="xld xlda pml mtm mbm">'
    '${pms.map(_pmNode).join()}</div></form></body></html>';

/// A broadcast message node (markup of test 185).
String _bmNode((int pmid, int at, bool unread) message) {
  final (pmid, at, unread) = message;
  final view = 'home.php?mod=space&amp;do=pm&amp;subop=viewg&amp;pmid=$pmid';
  return '<dl id="gpmlist_$pmid" class="bbda cur1 cl${unread ? ' newpm' : ''}">\n'
      '<dd class="y mtm pm_o"><a href="javascript:;" id="pm_g_$pmid" class="o">菜单</a></dd>\n'
      '<dd class="m avt">${unread ? '<div class="newpm_avt" title="有未读消息"></div>' : ''}\n'
      '<a href="$view"><img src="a.png" alt="" /></a>\n</dd>\n<dd class="ptm pm_c">\n'
      '<span id="p_gpmid_$pmid">Broadcast $pmid</span> &nbsp;\n'
      '<span class="xg1"><span title="${_timeOf(at)}">9&nbsp;小时前</span></span>&nbsp;\n'
      '<a href="$view" id="gpmlist_${pmid}_a">查看</a>\n</dd>\n</dl>\n';
}

/// The broadcast message page.
String _bmPage(List<(int pmid, int at, bool unread)> messages) =>
    '<html><body><div id="um"></div><div class="pml">${messages.map(_bmNode).join()}</div></body></html>';

/// One answer of the fake forum.
final class _Answer {
  const _Answer(this.body, {this.status = 200, this.type = 'text/html', this.date});

  _Answer.json(Object? json, {int status = 200}) : this(jsonEncode(json), status: status, type: 'application/json');

  final String body;
  final int status;
  final String type;
  final DateTime? date;
}

/// No answer at all: the network is down.
const _offline = _Answer('offline', status: 0);

/// HTTP 429 of the plugin: the same action of the same account within its interval.
final _busy = _Answer.json({'ok': 0, 'error': 'busy', 'retry_after': 3}, status: 429);

/// What Discuz itself answers a POST with a form hash it does not take, before the plugin is reached.
const _systemError = _Answer(
  '<!DOCTYPE html><html><head><title>System Error</title></head><body>System Error</body></html>',
);

/// Answers every action of the app API and every notification page from its fields; a request without an answer
/// fails the test. Records the requests in order and the forms posted to `seen`.
final class _Forum implements HttpClientAdapter {
  _Forum({this.notify, this.pmlist, this.seen, this.noticePage, this.pmPage, this.broadcastPage});

  _Answer? notify;
  _Answer? pmlist;
  _Answer? seen;
  _Answer? noticePage;
  _Answer? pmPage;
  _Answer? broadcastPage;

  final requests = <RequestOptions>[];
  final seenForms = <Map<String, String>>[];
  final unexpected = <String>[];

  List<String> get names => requests.map(_name).toList();

  static String _name(RequestOptions r) {
    final q = r.uri.queryParameters;
    if (q['id'] == 'tsdmapp:api') {
      return q['action'] ?? '?';
    }
    if (q['do'] == 'notice') {
      return 'notice page';
    }
    return switch (q['filter']) {
      'privatepm' => 'pm page',
      'announcepm' => 'broadcast page',
      _ => '${r.method} ${r.uri}',
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final name = _name(options);
    if (requestStream != null) {
      final body = utf8.decode(await requestStream.expand((e) => e).toList());
      if (name == 'seen' && options.method == 'POST') {
        seenForms.add(Uri.splitQueryString(body));
      }
    }
    final answer = switch (name) {
      'notify' => notify,
      'pmlist' => pmlist,
      'seen' => seen,
      'notice page' => noticePage,
      'pm page' => pmPage,
      'broadcast page' => broadcastPage,
      _ => null,
    };
    if (answer == null) {
      unexpected.add('${options.method} ${options.uri}');
      throw DioException.connectionError(requestOptions: options, reason: 'unexpected request');
    }
    if (identical(answer, _offline)) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: ['${answer.type}; charset=utf-8'],
        if (answer.date != null) 'date': [HttpDate.format(answer.date!)],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

Future<Either<AppException, FetchedNotification>> _run(_Forum forum, {int? timestamp, bool bypassGate = false}) =>
    NotificationRepository().fetchNotificationWith(_client(forum), timestamp: timestamp, bypassGate: bypassGate).run();

Future<FetchedNotification> _fetch(_Forum forum, {int? timestamp, bool bypassGate = false}) async {
  final result = await _run(forum, timestamp: timestamp, bypassGate: bypassGate);
  expect(forum.unexpected, isEmpty, reason: 'requests nobody answers');
  return result.getOrElse((e) => fail('fetch failed: $e'));
}

/// The seen answer of plugin 1.9.0.
final _seenOk = _Answer.json({'ok': 1, 'api': 1, 'time': _now, 'uid': _uid, 'notice': 1, 'newer': 0, 'pm': 1});

DateTime _clock(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

/// The raw body of notice [id] on a notice page, as the forum stores it (`$value[note]` is printed as it is).
String _rawNote(String page, int id) => RegExp(
  'id="notice_$id">.*?<dd class="ntc_body"[^>]*>(.*?)</dd>',
  dotAll: true,
).firstMatch(page)![1]!.trim();

int _secondsOf(DateTime local) => local.millisecondsSinceEpoch ~/ 1000;

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(getIt.reset);
  setUp(TsdmAppApi.reset);

  group('conversions', () {
    test('a notice of notify is the notice the notice page shows (pages of the forum)', () {
      for (final (file, id, unread, type, at) in [
        ('notice_unread_x5.html', 1984, true, 'post', DateTime(2026, 9, 5, 17, 38, 37)),
        ('notice_read_x5.html', 1984, false, 'post', DateTime(2026, 9, 5, 17, 38, 2)),
        // Two id attributes on the node (a friend request), see NotificationV2.noticeNodes.
        ('notice_friend_request_x5.html', 2436, true, 'friend', DateTime(2026, 9, 6, 20, 23, 59)),
      ]) {
        const author = 1000;
        final page = _data(file);
        final fromPage = NotificationV2.noticeNodes(parseHtmlDocument(page)).map(Notice.toV2).single!;
        final fromApi = Notice.toV2FromApi(
          _notice(id, _secondsOf(at), unread: unread, authorId: author, type: type, note: _rawNote(page, id)),
        );
        expect(fromApi, fromPage, reason: file);
        expect((fromApi!.ignoreType, fromApi.authorId), (type, author), reason: file);
        expect(fromApi.data, contains('href="$baseUrl/home.php?mod=space'), reason: 'absolute urls, $file');
        expect(fromApi.data, isNot(contains('href="home.php')), reason: file);
      }
    });

    test('a system notice (author 0), a smiley and a time inside the minute match the page as well', () {
      for (final n in [
        _notice(7, _since + 125),
        _notice(8, _since + 59, unread: false, authorId: 0, type: 'system', note: '您的帖子被 <b>管理员</b> 移动'),
      ]) {
        final fromPage = NotificationV2.noticeNodes(parseHtmlDocument(_noticePage([n]))).map(Notice.toV2).single;
        final fromApi = Notice.toV2FromApi(n);
        expect(fromApi, fromPage);
        expect(fromApi!.timestamp % 60, 0, reason: 'the minute the page shows');
      }
      final system = Notice.toV2FromApi(_notice(8, _since, authorId: 0, type: 'system', note: 'x'))!;
      expect((system.ignoreType, system.authorId), ('system', 0));
      expect(Notice.toV2FromApi(_notice(9, _since)..remove('note')), isNull);
      expect(Notice.toV2FromApi(_notice(9, _since)..['dateline'] = '1'), isNull);
    });

    test('the conversations of pmlist: the sender, the read state, no group chat', () {
      final at = _since + 125;
      final valid = [
        _pm(1, peer: 3001, at: at, unread: true, text: 'unread from the peer'),
        _pm(2, peer: 3002, at: at + 60, sentByMe: true, unread: true, text: 'sent by me'),
        _pm(3, peer: 3003, at: at - 3600, text: 'read on the web'),
      ];
      final list = PersonalMessage.listFromApi(
        _pmlist([
          ...valid,
          _pm(4, peer: 0, at: at, type: 2, name: ''),
          _pm(5, peer: 3005, at: 0),
          _pm(6, peer: 3006, at: at, name: ''),
          _pm(7, peer: 0, at: at),
        ]),
      )!;
      expect(list.map((e) => (e.peerUid, e.peerUsername, e.sender, e.alreadyRead, e.data)), [
        (3001, 'Peer3001', false, false, 'unread from the peer'),
        (3002, 'Peer3002', true, true, 'sent by me'),
        (3003, 'Peer3003', false, true, 'read on the web'),
      ]);
      expect(list.first.timestamp, at - at % 60);
      expect(list, NotificationV2.personalMessagesOf(parseHtmlDocument(_pmPage(valid))), reason: 'same as the page');

      expect(PersonalMessage.listFromApi(null), isNull);
      expect(PersonalMessage.listFromApi({'ok': 0, 'error': 'busy'}), isNull);
      expect(PersonalMessage.listFromApi(_pmlist(valid)..remove('uid')), isNull);
      expect(PersonalMessage.listFromApi(_pmlist(valid)..['pms'] = 'x'), isNull);
      // Private messages switched off on the forum: no conversation, as on its page.
      expect(PersonalMessage.listFromApi(_pmlist([], closed: 1)), isEmpty);
    });

    test('the broadcast messages of notify', () {
      final dateline = _now - 30 * 24 * 3600 + 17;
      final message = BroadcastMessage.toV2FromApi(_announce(7, dateline, 'Synthetic broadcast'))!;
      expect(
        (message.pmid, message.timestamp, message.data, message.alreadyRead),
        (
          7,
          dateline - dateline % 60,
          'Synthetic broadcast',
          false,
        ),
      );
      expect(BroadcastMessage.toV2FromApi(_announce(7, dateline, 'x')..remove('id')), isNull);
    });

    test('the private message page: unread is the row marked newpm, not the red dot every row has', () {
      final page = _data('pm_list_bare_url_x5.html');
      PersonalMessageV2 parse(String html) =>
          PersonalMessage.toV2(parseHtmlDocument(html).querySelector('dl[id^="pmlist_"]')!)!;
      expect(parse(page).alreadyRead, isFalse);
      final read = page.replaceFirst('class="bbda cur1 cl newpm"', 'class="bbda cur1 cl"');
      expect(read, isNot(page));
      expect(parseHtmlDocument(read).querySelector('dl[id^="pmlist_"] div.newpm_avt'), isNotNull);
      expect(parse(read).alreadyRead, isTrue, reason: 'Discuz! X5 prints the red dot in every row');
    });
  });

  group('plugin 1.9.0', () {
    test('a poll with new notices reads them from notify only and marks them seen as of its clock', () async {
      final notices = [
        _notice(105, _since + 300),
        _notice(101, _since + 125),
        _notice(99, _since + 61, unread: false),
        // notify lists every unread notice; this one is before the window, so not kept, but read on the forum too.
        _notice(110, _since - 3600),
      ];
      // The clock of the answer, not of the device nor an id: a notice updated in place keeps its id (see
      // notifyListsUnreadNotice).
      final forum = _Forum(
        notify: _Answer.json(_notify(notices: notices, time: _now - 5)),
        seen: _seenOk,
      );
      final value = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify', 'seen']);
      expect(forum.requests.last.method, 'POST');
      expect(forum.seenForms.single, {'formhash': _formhash, 'notice': '${_now - 5}'});

      final fromPages = NotificationV2.fromDocuments(
        noticeDoc: parseHtmlDocument(_noticePage(notices)),
        personalMessageDoc: parseHtmlDocument(_pmPage([])),
        broadcastMessageDoc: parseHtmlDocument(_bmPage([])),
        since: _since,
      );
      expect(value.info.noticeList.map((e) => e.id), [105, 101, 99]);
      expect(value.info.noticeList, fromPages.noticeList, reason: 'the notices the notice page shows');
      expect(value.info.noticeList.first.data, contains('href="$baseUrl/forum.php?mod=redirect'));
      expect(value.info.noticeList.first.data, contains('src="$baseUrl/static/image/smiley/default/smile.gif"'));
      expect((value.info.noticeList.first.ignoreType, value.info.noticeList.first.authorId), ('post', 3001));
      expect(value.info.personalMessageList, isEmpty);
      expect(value.serverTime, _clock(_now - 5), reason: 'the clock of notify');
      expect(value.window, _since);
    });

    test('new notices all read already: nothing to mark seen', () async {
      final forum = _Forum(notify: _Answer.json(_notify(notices: [_notice(99, _since + 61, unread: false)])));
      final value = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify']);
      expect(value.info.noticeList.map((e) => (e.id, e.alreadyRead)), [(99, true)]);
    });

    test('nothing new: notify only', () async {
      final forum = _Forum(notify: _Answer.json(_notify(pmLast: _since - 60)));
      final value = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify']);
      expect(value.info, NotificationV2.empty);
      expect(value.serverTime, _clock(_now));
    });

    test('nothing new, yet unread notices before the window: seen again (an earlier one failed)', () async {
      final forum = _Forum(
        notify: _Answer.json(
          _notify(notices: [_notice(90, _since - 3600), _notice(95, _since - 600), _notice(80, _since - 7200)]),
        ),
        seen: _seenOk,
      );
      final value = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify', 'seen']);
      expect(forum.seenForms.single, {'formhash': _formhash, 'notice': '$_now'});
      expect(value.info, NotificationV2.empty);
      expect(value.serverTime, _clock(_now));

      // Failing again changes nothing either.
      final failing = _Forum(notify: forum.notify, seen: _busy);
      expect((await _fetch(failing, timestamp: _since)).info, NotificationV2.empty);
      expect(failing.names, ['notify', 'seen']);
    });

    test('nothing new and every notice read: no seen', () async {
      final forum = _Forum(notify: _Answer.json(_notify(notices: [_notice(90, _since - 3600, unread: false)])));
      final value = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify']);
      expect(value.info, NotificationV2.empty);
    });

    test('a conversation changed: pmlist instead of the private message page, seen clears the prompt', () async {
      final rows = [
        _pm(1, peer: 3001, at: _since + 130, unread: true, text: 'new'),
        _pm(2, peer: 3002, at: _since + 200, sentByMe: true, text: 'sent'),
        _pm(3, peer: 3003, at: _since - 7200, text: 'before the window'),
        _pm(4, peer: 0, at: _since + 100, type: 2, name: ''),
      ];
      // Told by pm_last (plugin 1.8.0) or by an unread received conversation in pms.
      for (final notify in [
        _notify(pmLast: _since + 200),
        _notify(pms: [rows.first]),
      ]) {
        final forum = _Forum(notify: _Answer.json(notify), pmlist: _Answer.json(_pmlist(rows)), seen: _seenOk);
        final value = await _fetch(forum, timestamp: _since);
        expect(forum.names, ['notify', 'pmlist', 'seen']);
        expect(forum.seenForms.single, {'formhash': _formhash, 'pm': '1'});
        expect(value.info.personalMessageList.map((e) => (e.peerUid, e.sender, e.alreadyRead, e.data)), [
          (3001, false, false, 'new'),
          (3002, true, true, 'sent'),
        ]);
      }
    });

    test('private messages switched off on the forum: no conversation, no prompt to clear', () async {
      final forum = _Forum(
        notify: _Answer.json(_notify(pmLast: _since + 200)),
        pmlist: _Answer.json(_pmlist([], closed: 1)),
      );
      final value = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify', 'pmlist']);
      expect(value.info.personalMessageList, isEmpty);
    });

    test('no conversation changed: pmlist is not asked', () async {
      final forum = _Forum(
        notify: _Answer.json(_notify(notices: [_notice(101, _since + 125)], pmLast: _since)),
        seen: _seenOk,
      );
      final value = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify', 'seen']);
      expect(forum.seenForms.single, {'formhash': _formhash, 'notice': '$_now'});
      expect(value.info.personalMessageList, isEmpty);
    });

    test('pmlist refused as too soon or not understood: the private message page', () async {
      final rows = [
        _pm(1, peer: 3001, at: _since + 130, unread: true, text: 'from the page'),
        _pm(3, peer: 3003, at: _since - 7200, text: 'before the window'),
      ];
      for (final answer in [
        _busy,
        _offline,
        _Answer.json({'ok': 0, 'error': 'internal'}),
        _Answer.json({'ok': 0, 'error': 'action'}),
        _Answer.json(_pmlist(rows)..['pms'] = 'x'),
      ]) {
        final forum = _Forum(
          notify: _Answer.json(_notify(pmLast: _since + 130)),
          pmlist: answer,
          pmPage: _Answer(_pmPage(rows)),
        );
        final value = await _fetch(forum, timestamp: _since);
        expect(forum.names, ['notify', 'pmlist', 'pm page'], reason: answer.body);
        expect(forum.seenForms, isEmpty, reason: 'reading the page cleared the prompt');
        expect(value.info.personalMessageList.map((e) => (e.peerUid, e.alreadyRead, e.data)), [
          (3001, false, 'from the page'),
        ]);
        expect(TsdmAppApi.knownUnavailable, isFalse);
      }
    });

    test('pmlist tells the session expired', () async {
      final forum = _Forum(
        notify: _Answer.json(_notify(pmLast: _since + 130)),
        pmlist: _Answer.json({'ok': 0, 'error': 'login'}),
      );
      final result = await _run(forum, timestamp: _since);
      expect(result.getLeft().toNullable(), isA<NotificationUserNotFound>());
      expect(forum.names, ['notify', 'pmlist']);
    });

    test('a refresh: notify, every conversation of pmlist and the broadcast page; not the other two pages', () async {
      final old = _now - 5 * 24 * 3600;
      final forum = _Forum(
        notify: _Answer.json(_notify(notices: [_notice(101, _since + 125)], announces: [_announce(9, old, 'x')])),
        pmlist: _Answer.json(
          _pmlist([
            _pm(1, peer: 3001, at: _since + 130, unread: true),
            _pm(2, peer: 3002, at: old, sentByMe: true, text: 'written days ago'),
          ]),
        ),
        broadcastPage: _Answer(_bmPage([(9, old, true), (8, old, false), (7, _since + 60, false)])),
        seen: _seenOk,
      );
      final value = await _fetch(forum, timestamp: _since, bypassGate: true);
      expect(forum.names.first, 'notify');
      expect(forum.names.sublist(1, 3), unorderedEquals(['pmlist', 'broadcast page']));
      expect(forum.names.last, 'seen');
      expect(forum.names, hasLength(4));
      expect(forum.seenForms.single, {'formhash': _formhash, 'notice': '$_now', 'pm': '1'});
      expect(value.info.noticeList.map((e) => e.id), [101]);
      expect(value.info.personalMessageList.map((e) => e.peerUid), [3001, 3002], reason: 'whatever their time, #193');
      expect(
        value.info.broadcastMessageList.map((e) => (e.pmid, e.alreadyRead)),
        [(9, false), (7, true)],
        reason: 'the page: unread ones whatever their time, read ones inside the window',
      );
    });

    test('the first fetch: the same, conversations of the three days only', () async {
      final forum = _Forum(
        notify: _Answer.json(_notify()),
        pmlist: _Answer.json(
          _pmlist([
            _pm(1, peer: 3001, at: _now - 3600),
            _pm(2, peer: 3002, at: _now - 5 * 24 * 3600),
          ]),
        ),
        broadcastPage: _Answer(_bmPage([])),
        seen: _seenOk,
      );
      final value = await _fetch(forum);
      expect(forum.names, hasLength(4));
      expect(forum.names, containsAll(<String>['notify', 'pmlist', 'broadcast page', 'seen']));
      expect(forum.seenForms.single, {'formhash': _formhash, 'pm': '1'});
      expect(value.info.personalMessageList.map((e) => e.peerUid), [3001]);
      expect(value.window, closeTo(_now - 3 * 24 * 3600, 5));
    });

    test('a poll takes the unread broadcast messages from notify, whatever their time (#154)', () async {
      final written = _now - 30 * 24 * 3600;
      final forum = _Forum(notify: _Answer.json(_notify(announces: [_announce(7, written, 'Synthetic broadcast')])));
      final value = await _fetch(forum, timestamp: _since);
      expect(forum.names, ['notify']);
      expect(value.info.broadcastMessageList.map((e) => (e.pmid, e.data, e.alreadyRead)), [
        (7, 'Synthetic broadcast', false),
      ]);
    });

    test('the clock of the fetch: the earliest of notify and the pages read', () async {
      for (final (pageOffset, expected) in [(-30, _now - 30), (30, _now)]) {
        final forum = _Forum(
          notify: _Answer.json(_notify()),
          pmlist: _Answer.json(_pmlist([])),
          broadcastPage: _Answer(_bmPage([]), date: _clock(_now + pageOffset)),
          seen: _seenOk,
        );
        final value = await _fetch(forum, timestamp: _since, bypassGate: true);
        expect(value.serverTime, _clock(expected));
      }
    });

    test('seen refused, offline, or answered the System Error page: the same result, the API stays in use', () async {
      for (final answer in [
        _busy,
        _offline,
        _systemError,
        _Answer.json({'ok': 0, 'error': 'formhash'}),
      ]) {
        final forum = _Forum(
          notify: _Answer.json(_notify(notices: [_notice(101, _since + 125)])),
          seen: answer,
        );
        final value = await _fetch(forum, timestamp: _since);
        expect(forum.names, ['notify', 'seen'], reason: answer.body);
        expect(value.info.noticeList.map((e) => e.id), [101]);
        expect(value.serverTime, _clock(_now));
        expect(TsdmAppApi.knownUnavailable, isFalse, reason: 'a write that failed says nothing about the plugin');
      }
    });

    test('each account posts the form hash of its own notify answer', () async {
      _Forum forum(String formhash) => _Forum(
        notify: _Answer.json(_notify(notices: [_notice(101, _since + 125)], formhash: formhash)),
        seen: _seenOk,
      );
      final (alice, bob) = (forum('aaaa1111'), forum('bbbb2222'));
      await Future.wait([_fetch(alice, timestamp: _since), _fetch(bob, timestamp: _since)]);
      expect(alice.seenForms.single['formhash'], 'aaaa1111');
      expect(bob.seenForms.single['formhash'], 'bbbb2222');
    });
  });

  group('notify tells the session expired', () {
    for (final (mode, timestamp, bypass) in [
      ('a poll', _since, false),
      ('a refresh', _since, true),
      ('the first fetch', null, false),
    ]) {
      test('$mode: no page', () async {
        final forum = _Forum(notify: _Answer.json({'ok': 0, 'error': 'login'}));
        final result = await _run(forum, timestamp: timestamp, bypassGate: bypass);
        expect(result.getLeft().toNullable(), isA<NotificationUserNotFound>());
        expect(forum.names, ['notify']);
      });
    }
  });

  group('an older plugin or none: the three pages as before', () {
    const pages = ['notice page', 'pm page', 'broadcast page'];
    final notices = [_notice(101, _since + 125)];
    _Forum forum(_Answer notify) => _Forum(
      notify: notify,
      noticePage: _Answer(_noticePage(notices)),
      pmPage: _Answer(_pmPage([_pm(1, peer: 3001, at: _since + 130, unread: true)])),
      broadcastPage: _Answer(_bmPage([])),
    );

    test('plugin 1.8.0, a poll with news: notify, then the three pages', () async {
      final old = forum(_Answer.json(_notify(notices: notices, pmLast: _since + 130, lists: false)));
      final value = await _fetch(old, timestamp: _since);
      expect(old.names.first, 'notify');
      expect(old.names.skip(1), unorderedEquals(pages));
      expect(value.info.noticeList.map((e) => e.id), [101]);
      expect(value.info.personalMessageList.map((e) => e.peerUid), [3001]);
    });

    test('plugin 1.8.0, a poll with nothing new: notify only, even with unread notices (no seen)', () async {
      for (final notices in [
        <Map<String, Object?>>[],
        [_notice(90, _since - 3600)],
      ]) {
        final old = forum(_Answer.json(_notify(notices: notices, lists: false)));
        final value = await _fetch(old, timestamp: _since);
        expect(old.names, ['notify']);
        expect(value.info, NotificationV2.empty);
      }
    });

    test('plugin 1.8.0, a refresh and the first fetch: notify is asked, its answer ignored, the three pages', () async {
      for (final (timestamp, bypass) in [(_since, true), (null, false)]) {
        final old = forum(_Answer.json(_notify(lists: false)));
        final value = await _fetch(old, timestamp: timestamp, bypassGate: bypass);
        expect(old.names.first, 'notify');
        expect(old.names.skip(1), unorderedEquals(pages));
        expect(value.info.noticeList.map((e) => e.id), [101]);
      }
    });

    test('notify refused as too soon: the three pages', () async {
      final busy = forum(_busy);
      await _fetch(busy, timestamp: _since);
      expect(busy.names.first, 'notify');
      expect(busy.names.skip(1), unorderedEquals(pages));
    });

    test('no plugin: the three pages, and the API is not asked again for an hour', () async {
      final none = forum(const _Answer('<html><body><div id="messagetext"><p>插件不存在或已关闭</p></div></body></html>'));
      await _fetch(none, timestamp: _since, bypassGate: true);
      expect(none.names.first, 'notify');
      expect(none.names.skip(1), unorderedEquals(pages));
      expect(TsdmAppApi.knownUnavailable, isTrue);
      none.requests.clear();
      await _fetch(none, timestamp: _since);
      expect(none.names, unorderedEquals(pages));
    });
  });
}
