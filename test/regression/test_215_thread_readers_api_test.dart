/// The other readers of a thread page on the structured answer of the forum's app API (plugin 2.1.0, `schema: 3`).
///
/// test_214 moved the thread page itself (`ThreadRepository.fetchThreadPage`) onto the structured answer. The
/// readers that asked a thread page for one thing and parsed it themselves follow here, each on both paths: built
/// from the fields of a structured answer, parsed from the document of any other answer (the web page, an older
/// plugin's answer) exactly as before.
///
/// * the thread page's author lookup (`ThreadRepository.fetchThreadFirstPage`, who started a thread opened on a
///   later page while somebody is blocked);
/// * the post of a notice (`NotificationRepository.fetchNoticeThread`, `NotificationDetailCubit`);
/// * a thread saved as a draft confirmed (`PostEditRepository.confirmsDraft`, `thread.draft`);
/// * a poll's thread verified after its creation (`PollCreateRepository`, `classifyNewThreadApi`);
/// * a report prepared on a fresh thread page (`PostReportRepository.prepare`, `can.report`);
/// * a draft opened from the draft box (`DraftRepository.resolve`, `urls.edit`).
///
/// The structured answers are the fixtures of test_214 (`test/data/tsdmapp/thread_v3_*.json`), a field changed where
/// the test forum had no such thread (a draft, a thread awaiting moderation, an anonymous first floor); the documents
/// are the web page `thread_plain.html`, the answer `thread_plain.json` of plugin 2.0.0 and the synthetic pages of
/// the readers' own tests.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/draft_box/repository/draft_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_detail_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/utils/new_thread_status.dart';
import 'package:tsdm_client/features/post_report/models/post_report.dart';
import 'package:tsdm_client/features/post_report/repository/post_report_repository.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:universal_html/parsing.dart';

import 'draft_fixtures.dart';
import 'fixtures/post_report_fixtures.dart';
import 'poll_fixtures.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// The thread of `thread_v3_plain.json`: tid 9199345 in forum 2, started by uid 32, served to uid 35, whose first
/// floor is pid 3938 and whose reply pid 3954 is by uid 33.
const _plainTid = '9199345';
const _plainFid = 2;
const _plainUid = 35;
const _plainAuthor = '32';
const _plainFirstPid = 3938;
const _plainReplyPid = 3954;

/// `thread_v3_plain.json` with [thread] fields changed, [posts] applied to each floor, and the account [uid] it was
/// served to.
Map<String, dynamic> _plain({
  Map<String, Object?> thread = const {},
  Map<String, dynamic> Function(Map<String, dynamic> post)? posts,
  int? uid,
}) {
  final json = _json('thread_v3_plain.json');
  json['thread'] = {...json['thread'] as Map<String, dynamic>, ...thread};
  if (posts != null) {
    json['posts'] = [for (final p in json['posts'] as List) posts(Map<String, dynamic>.from(p as Map))];
  }
  if (uid != null) {
    json['uid'] = uid;
  }
  return json;
}

/// The forum's message of plugin 2.1.0 to a member without permission (`login` 0): the thread is not shown. The
/// message names no account; plugin 2.2.0 adds the `uid` it was served to ([_messageTo]).
const Map<String, Object?> _memberMessage = {
  'ok': 0,
  'error': 'message',
  'message': '抱歉，本帖要求阅读权限高于 20 才能浏览',
  'login': 0,
  'schema': 3,
};

/// The forum's message of plugin 2.2.0, served to [uid] (0: a guest, with the login prompt).
Map<String, Object?> _messageTo(int uid) => {..._memberMessage, 'login': uid > 0 ? 0 : 1, 'uid': uid};

/// The floor [p] with its `can` fields changed by [can].
Map<String, dynamic> _can(Map<String, dynamic> p, Map<String, int> can) => {
  ...p,
  'can': {...Map<String, dynamic>.from(p['can'] as Map), ...can},
};

/// The first floor of `thread_v3_plain.json` made anonymous, as the forum answers it to a member.
Map<String, dynamic> _anonymousFirst(Map<String, dynamic> p) =>
    p['first'] == 1 ? {...p, 'anonymous': 1, 'authorid': 0, 'author': '', 'avatar': '', 'signature_html': ''} : p;

/// A synthetic web page of thread 123 served to uid 1000, with one first floor (pid 456) by [author]: a user link as
/// the real page prints it, or plain text (an anonymous or guest post). The shape of the blocking tests (test_095).
/// The test forum's own page (`thread_plain.html`) prints its first floor as "楼主" instead of a number, which the post
/// parser does not read as floor 1 on any path: it cannot tell who started a thread there, as before.
String _threadPage({String author = '<a href="home.php?mod=space&amp;uid=1000" class="xi2">Test author</a>'}) =>
    draftPage('''
<div id="postlist"><h1 class="ts"><span id="thread_subject">Synthetic subject</span></h1><div class="bm">
<div id="post_456"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=viewthread&amp;tid=123"><em>1</em></a>
</strong><div class="authi">$author&nbsp;<em id="authorposton456">发表于 2026-9-20 10:00</em></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_456">Synthetic body</div></div></div></td>
</tr></tbody></table></div>
</div></div>''');

/// The answer of an older plugin (2.0.0, no `schema`): the blocks of the page in its `document`, with the
/// `discuz_uid` the plugin keeps in it.
Map<String, Object?> _olderAnswer(String html) => {
  'ok': 1,
  'type': 'thread',
  'head': '',
  'document': "<script>var discuz_uid = '1000';</script>${parseHtmlDocument(html).body!.innerHtml}",
};

/// One answer of the forum: its body, served as JSON or as the web page, where the forum redirected to.
typedef _Answer = ({String body, bool json, String? redirectTo});

_Answer _html(String body, {String? redirectTo}) => (body: body, json: false, redirectTo: redirectTo);

/// A JSON answer of the plugin. The plugin's answer carries the blocks of the page (`document`) beside the structured
/// fields, which the fixtures dropped: one is put back (empty) so the answer is a page to the antitheft interceptor,
/// as it is on the forum; the structured path never reads it.
_Answer _api(Object answer, {String? redirectTo}) {
  final json = answer is String ? jsonDecode(answer) : answer;
  final body = json is Map && !json.containsKey('document') ? {...json, 'document': ''} : json;
  return (body: jsonEncode(body), json: true, redirectTo: redirectTo);
}

/// A JSON answer of the plugin as it is: one without a page.
_Answer _apiAsIs(String answer) => (body: answer, json: true, redirectTo: null);

/// A forum answering every request as [answer] says, recording the requests.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  _Forum.always(_Answer answer) : this((_) => answer);

  final _Answer Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final a = answer(options);
    final body = ResponseBody.fromString(
      a.body,
      200,
      headers: {
        Headers.contentTypeHeader: [if (a.json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
    if (a.redirectTo != null) {
      body.redirects = [RedirectRecord(302, options.method, Uri.parse(a.redirectTo!))];
    }
    return body;
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

/// Make [forum] the forum of the app's default client.
void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(() => _client(forum));

bool _asksJson(RequestOptions r) => r.uri.queryParameters['tsdmapp'] == 'json';

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

/// A response of the injected transports of the editor and poll repositories: the web page as text, or the JSON
/// answer as dio decodes it.
Response<dynamic> _response(Object? data, {int status = 200, String? location}) => Response<dynamic>(
  requestOptions: RequestOptions(),
  data: data,
  statusCode: status,
  headers: Headers.fromMap({
    if (location != null) 'location': [location],
  }),
);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('threadApiAnswerOf', () {
    test('a thread answer only: the page of another type with its own schema is not one', () {
      expect(threadApiAnswerOf(_plain()), isNotNull);
      expect(threadApiAnswerOf({..._plain(), 'type': 'profile', 'schema': 4}), isNull);
      expect(threadApiAnswerOf({..._plain(), 'type': 'forum', 'schema': 2}), isNull);
      expect(threadApiAnswerOf(_messageTo(_plainUid)), isNotNull, reason: 'the message, whatever its type');
    });
  });

  group('threadApiViewerUid', () {
    test('the account the answer was served to, none for a guest or the message', () {
      expect(threadApiViewerUid(_json('thread_v3_plain.json')), _plainUid);
      expect(threadApiViewerUid(_json('thread_v3_plain_guest.json')), isNull);
      expect(threadApiViewerUid(_json('thread_v3_denied_guest.json')), isNull);
      expect(threadApiViewerUid(_json('thread_v3_denied.json')), _plainUid);
      expect(threadApiViewerUid(const {'ok': 1, 'uid': '7'}), 7);
      expect(threadApiViewerUid(const {'ok': 1, 'uid': -1}), isNull);
    });
  });

  group('the author of a thread (ThreadRepository.fetchThreadFirstPage)', () {
    test('built: the first floor names the author; its page asked oldest first in JSON mode', () async {
      final forum = _Forum.always(_api(_raw('thread_v3_plain.json')));
      _use(forum);
      final v = _right(await ThreadRepository().fetchThreadFirstPage(tid: _plainTid).run());
      expect(v.page.postList.firstWhere((e) => e.postFloor == 1).author.uid, _plainAuthor);
      expect(v.firstFloorNamesNoUser, isFalse);
      expect(v.page.havePermission, isTrue);
      final request = forum.requests.single;
      expect(_asksJson(request), isTrue);
      expect(request.uri.queryParameters, containsPair('ordertype', '2'));
      expect(request.uri.queryParameters, containsPair('page', '1'));
      expect(request.uri.queryParameters, containsPair('tid', _plainTid));
    });

    test('built: an anonymous first floor names no user', () async {
      _use(_Forum.always(_api(_plain(posts: _anonymousFirst))));
      final v = _right(await ThreadRepository().fetchThreadFirstPage(tid: _plainTid).run());
      final first = v.page.postList.firstWhere((e) => e.postFloor == 1);
      expect(first.author.uid, isNull);
      expect(v.firstFloorNamesNoUser, isTrue);
    });

    test('built: a later floor by a guest is not the first floor', () async {
      _use(
        _Forum.always(
          _api(_plain(posts: (p) => p['pid'] == _plainReplyPid ? {...p, 'anonymous': 1, 'authorid': 0} : p)),
        ),
      );
      final v = _right(await ThreadRepository().fetchThreadFirstPage(tid: _plainTid).run());
      expect(v.firstFloorNamesNoUser, isFalse);
      expect(v.page.postList.firstWhere((e) => e.postFloor == 1).author.uid, _plainAuthor);
    });

    test('built: the login prompt of a guest and the denied message name nobody', () async {
      _use(_Forum.always(_api(_raw('thread_v3_denied_guest.json'))));
      final guest = _right(await ThreadRepository().fetchThreadFirstPage(tid: '9199132').run());
      expect(guest.page.needLogin, isTrue);
      expect(guest.page.postList, isEmpty);
      expect(guest.firstFloorNamesNoUser, isFalse);
      _use(_Forum.always(_api(_memberMessage)));
      final denied = _right(await ThreadRepository().fetchThreadFirstPage(tid: '9199132').run());
      expect(denied.page.havePermission, isFalse);
      expect(denied.page.postList, isEmpty, reason: 'the thread is not shown to this account');
      expect(denied.firstFloorNamesNoUser, isFalse);
    });

    test('the web page and the answer of an older plugin: parsed as before', () async {
      for (final answer in [_html(_threadPage()), _api(_olderAnswer(_threadPage()))]) {
        _use(_Forum.always(answer));
        final v = _right(await ThreadRepository().fetchThreadFirstPage(tid: '123').run());
        expect(v.page.postList.firstWhere((e) => e.postFloor == 1).author.uid, '1000', reason: '${answer.json}');
        expect(v.firstFloorNamesNoUser, isFalse);
      }
      // The test forum's page: no numbered first floor on either path, as before.
      for (final answer in [_html(_raw('thread_plain.html')), _api(_raw('thread_plain.json'))]) {
        _use(_Forum.always(answer));
        final v = _right(await ThreadRepository().fetchThreadFirstPage(tid: _plainTid).run());
        expect(v.page.postList.where((e) => e.postFloor == 1), isEmpty, reason: '${answer.json}');
        expect(v.firstFloorNamesNoUser, isFalse);
      }
    });

    test('the web page: an anonymous first floor is skipped by the post parser and read from the page', () async {
      final page = _threadPage(author: '匿名');
      expect(firstFloorNamesNoUser(parseHtmlDocument(page)), isTrue);
      for (final answer in [_html(page), _api(_olderAnswer(page))]) {
        _use(_Forum.always(answer));
        final v = _right(await ThreadRepository().fetchThreadFirstPage(tid: '123').run());
        expect(v.page.postList.where((e) => e.postFloor == 1), isEmpty, reason: '${answer.json}');
        expect(v.firstFloorNamesNoUser, isTrue, reason: '${answer.json}');
      }
    });

    test('an answer without a page is a failed request', () async {
      _use(_Forum.always(_apiAsIs('{"ok":0,"error":"internal"}')));
      final result = await ThreadRepository().fetchThreadFirstPage(tid: _plainTid).run();
      expect(result.getLeft().toNullable(), isA<HttpRequestFailedException>());
    });
  });

  group('the post of a notice (NotificationDetailCubit)', () {
    const findpostTid = '1125';
    const findpostPid = 200001;

    Future<NotificationDetailCubit> fetch(String url) async {
      final cubit = NotificationDetailCubit(notificationRepository: NotificationRepository());
      addTearDown(cubit.close);
      await cubit.fetchDetail(url);
      return cubit;
    }

    test('built: the floor, the reply form, the page the forum landed on, the thread open', () async {
      final answer = _json('thread_v3_findpost.json');
      final pid = (answer['posts'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['first'] != 1)['pid'];
      expect(pid, findpostPid, reason: 'the reply of the fixture the notice points to');
      final forum = _Forum.always(_api(answer));
      _use(forum);
      final cubit = await fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$findpostTid&pid=$findpostPid');
      final state = cubit.state;
      expect(state.status, NotificationDetailStatus.success);
      expect(state.post?.postID, '$findpostPid');
      expect(state.post?.reportTarget, isNotNull, reason: 'the thread the notice points to');
      expect(state.post?.reportTarget?.tid, 1125);
      expect(state.tid, findpostTid);
      expect(state.pid, '$findpostPid');
      expect(state.page, '${answer['page']}');
      expect(state.threadClosed, isFalse);
      expect(state.replyParameters?.formHash, answer['formhash']);
      expect(state.replyParameters?.tid, findpostTid);
      expect(state.replyParameters?.fid, '${(answer['thread'] as Map<String, dynamic>)['fid']}');
      expect(state.replyParameters?.postTime, (answer['reply'] as Map<String, dynamic>)['posttime']);
      expect(_asksJson(forum.requests.single), isTrue);
    });

    test('built: a page of another thread keeps the floor but drops its report target (#127)', () async {
      _use(_Forum.always(_api(_raw('thread_v3_findpost.json'))));
      final cubit = await fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=999&pid=$findpostPid');
      expect(cubit.state.status, NotificationDetailStatus.success);
      expect(cubit.state.post?.postID, '$findpostPid');
      expect(cubit.state.post?.reportTarget, isNull);
      expect(cubit.state.tid, '999');
    });

    test('built: a closed thread, and a thread without the fast reply form', () async {
      _use(_Forum.always(_api(_raw('thread_v3_closed.json'))));
      final closed = _json('thread_v3_closed.json');
      final pid = (closed['posts'] as List).cast<Map<String, dynamic>>().first['pid'];
      final tid = (closed['thread'] as Map<String, dynamic>)['tid'];
      final cubit = await fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$tid&pid=$pid');
      expect(cubit.state.status, NotificationDetailStatus.success);
      expect(cubit.state.threadClosed, isTrue, reason: 'reply.allowed 0');
      expect(cubit.state.replyParameters, isNotNull, reason: 'the form is printed, without its textarea');
    });

    test('built: a floor the forum no longer shows, and the message of the plugin, fail as before', () async {
      _use(_Forum.always(_api(_raw('thread_v3_findpost.json'))));
      final missing = await fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$findpostTid&pid=1');
      expect(missing.state.status, NotificationDetailStatus.failed);
      _use(_Forum.always(_api(_raw('thread_v3_denied_guest.json'))));
      final denied = await fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=9199132&pid=1');
      expect(denied.state.status, NotificationDetailStatus.failed);
    });

    test('the web page and the answer of an older plugin: parsed as before, the page from the redirect', () async {
      const to = '$baseUrl/forum.php?mod=viewthread&tid=$_plainTid&page=1#pid$_plainReplyPid';
      for (final answer in [
        _html(_raw('thread_plain.html'), redirectTo: to),
        _api(_raw('thread_plain.json'), redirectTo: '$to&tsdmapp=json'),
      ]) {
        _use(_Forum.always(answer));
        final cubit = await fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$_plainTid&pid=$_plainReplyPid');
        final state = cubit.state;
        final reason = 'json ${answer.json}';
        expect(state.status, NotificationDetailStatus.success, reason: reason);
        expect(state.post?.postID, '$_plainReplyPid', reason: reason);
        expect(state.post?.author.uid, '33', reason: reason);
        expect(state.tid, _plainTid, reason: reason);
        expect(state.pid, '$_plainReplyPid', reason: reason);
        expect(state.page, '1', reason: reason);
        expect(state.threadClosed, isFalse, reason: reason);
        // The test forum's page prints no search box (`srhfid`), which the reply form parser needs: no form, as before.
        expect(state.replyParameters, isNull, reason: reason);
      }
    });

    test('the web page: no page named when the forum did not redirect', () async {
      _use(_Forum.always(_html(_raw('thread_plain.html'))));
      final cubit = await fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$_plainTid&pid=$_plainReplyPid');
      expect(cubit.state.status, NotificationDetailStatus.success);
      expect(cubit.state.page, isNull);
    });

    test('fetchNoticeThread tells the two apart', () async {
      _use(_Forum.always(_api(_raw('thread_v3_plain.json'))));
      final built = _right(
        await NotificationRepository().fetchNoticeThread('$baseUrl/forum.php?mod=viewthread&tid=1').run(),
      );
      expect(built, isA<NoticeThreadPageBuilt>());
      expect((built as NoticeThreadPageBuilt).page.tid, _plainTid);
      _use(_Forum.always(_api(_raw('thread_plain.json'))));
      final document = _right(
        await NotificationRepository().fetchNoticeThread('$baseUrl/forum.php?mod=viewthread&tid=1').run(),
      );
      expect(document, isA<NoticeThreadPageDocument>());
      expect((document as NoticeThreadPageDocument).document.querySelector('div#post_$_plainReplyPid'), isNotNull);
      _use(_Forum.always(_apiAsIs('{"ok":0,"error":"internal"}')));
      final failed = await NotificationRepository().fetchNoticeThread('$baseUrl/forum.php?mod=viewthread&tid=1').run();
      expect(failed.getLeft().toNullable(), isA<HttpRequestFailedException>());
    });
  });

  group('a draft confirmed after saving (PostEditRepository.confirmsDraft)', () {
    const url = '$baseUrl/forum.php?mod=viewthread&tid=$_plainTid';

    Future<(bool, List<String>)> confirms(Object? answer, {int owner = _plainUid}) async {
      final gets = <String>[];
      final repo = PostEditRepository.withTransport(
        currentUid: () => owner,
        getPage: (u) async {
          gets.add(u);
          return right(_response(answer));
        },
        sendForm: (_, _) async => throw StateError('no post'),
      );
      return (await repo.confirmsDraft(url), gets);
    }

    test('built: thread.draft of the page served to the same account', () async {
      final (confirmed, gets) = await confirms(_plain(thread: {'draft': 1}));
      expect(confirmed, isTrue);
      expect(gets.single, withTsdmAppJson(url));
      expect(gets.single, contains('tsdmapp=json'));
    });

    test('built: not a draft, another account, a guest, the message: not confirmed', () async {
      expect((await confirms(_plain())).$1, isFalse, reason: 'draft 0');
      expect((await confirms(_plain(thread: {'draft': 1}), owner: 36)).$1, isFalse, reason: 'another account');
      expect((await confirms(_plain(thread: {'draft': 1}, uid: 0))).$1, isFalse, reason: 'a guest');
      expect((await confirms(_json('thread_v3_denied_guest.json'))).$1, isFalse, reason: 'the login prompt');
      expect((await confirms(_memberMessage)).$1, isFalse, reason: 'the message');
      expect((await confirms(_raw('thread_v3_plain.json').replaceFirst('"draft":0', '"draft":1'))).$1, isTrue);
    });

    test('the web page: the marker beside the title, the account from discuz_uid, as before', () async {
      expect((await confirms(draftThread(), owner: 1000)).$1, isTrue);
      expect((await confirms(draftThread(draft: false), owner: 1000)).$1, isFalse);
      expect((await confirms(draftThread(uid: 1001), owner: 1000)).$1, isFalse);
      expect((await confirms(_raw('thread_plain.html'), owner: 31)).$1, isFalse, reason: 'not a draft');
    });

    test('an answer without a page, a failed request: not confirmed', () async {
      expect((await confirms('')).$1, isFalse);
      expect((await confirms(const {'ok': 0, 'error': 'internal'})).$1, isFalse);
      final repo = PostEditRepository.withTransport(
        currentUid: () => _plainUid,
        getPage: (_) async => left(HttpRequestFailedException(500)),
        sendForm: (_, _) async => throw StateError('no post'),
      );
      expect(await repo.confirmsDraft(url), isFalse);
    });
  });

  group('a poll thread verified after its creation (PollCreateRepository)', () {
    const draft = PollDraft(
      subject: 'Synthetic poll',
      message: '',
      options: ['Alpha', 'Beta'],
      maxChoices: '1',
      expiry: '',
      visibleAfterVote: false,
      publicVoters: false,
      threadType: null,
      extraOptions: [],
    );

    /// Create the poll on a forum that redirects to thread [tid] and answers its page with [thread].
    Future<(PollCreateResult, List<String>)> create(
      Object? thread, {
      String tid = _plainTid,
      int uid = _plainUid,
    }) async {
      final gets = <String>[];
      final repo = PollCreateRepository.withTransport(
        currentUid: () => uid,
        getPage: (url) async {
          gets.add(url);
          return right(url.contains('viewthread') ? _response(thread) : _response(pollForm(uid: uid)));
        },
        sendForm: (_, _) async => right(_response('', status: 301, location: 'forum.php?mod=viewthread&tid=$tid')),
      );
      final form = (await repo.fetchForm('4')).form!;
      final result = await repo.submit(form, validatePollDraft(draft, form).submission!);
      return (result, gets.where((u) => u.contains('viewthread')).toList());
    }

    test('classifyNewThreadApi: the thread named, draft, moderating, visible, anything else unknown', () {
      expect(classifyNewThreadApi(_plain(), _plainTid), NewThreadHeaderStatus.visible);
      expect(classifyNewThreadApi(_plain(thread: {'draft': 1}), _plainTid), NewThreadHeaderStatus.draft);
      expect(classifyNewThreadApi(_plain(thread: {'displayorder': -2}), _plainTid), NewThreadHeaderStatus.moderating);
      expect(classifyNewThreadApi(_plain(thread: {'displayorder': -3}), _plainTid), NewThreadHeaderStatus.unknown);
      expect(classifyNewThreadApi(_plain(thread: {'displayorder': 1}), _plainTid), NewThreadHeaderStatus.unknown);
      expect(classifyNewThreadApi(_plain(), '321'), NewThreadHeaderStatus.unknown, reason: 'another thread');
      expect(classifyNewThreadApi(_json('thread_v3_denied_guest.json'), '9199132'), NewThreadHeaderStatus.unknown);
      expect(classifyNewThreadApi(const {'ok': 1}, _plainTid), NewThreadHeaderStatus.unknown);
    });

    test('built: a visible thread of the author is published, asked in JSON mode', () async {
      final (result, gets) = await create(_plain());
      expect(result.outcome, PollCreateOutcome.published);
      expect(result.tid, _plainTid);
      expect(gets.single, contains('tsdmapp=json'));
    });

    test('built: moderating is moderated, a draft or another thread unconfirmed, never published', () async {
      expect((await create(_plain(thread: {'displayorder': -2}))).$1.outcome, PollCreateOutcome.moderated);
      expect((await create(_plain(thread: {'draft': 1}))).$1.outcome, PollCreateOutcome.unconfirmed);
      expect((await create(_plain(), tid: '321')).$1.outcome, PollCreateOutcome.unconfirmed);
      expect((await create(_memberMessage, tid: '9199132')).$1.outcome, PollCreateOutcome.unconfirmed);
    });

    test('built: a page served to another account or a guest is not proof', () async {
      expect((await create(_plain(uid: 36))).$1.outcome, PollCreateOutcome.unconfirmed);
      expect((await create(_plain(uid: 0))).$1.outcome, PollCreateOutcome.unconfirmed);
    });

    test('the web page: the header, as before', () async {
      expect((await create(pollThread(), tid: '321', uid: 1000)).$1.outcome, PollCreateOutcome.published);
      expect(
        (await create(pollThread(label: '审核中'), tid: '321', uid: 1000)).$1.outcome,
        PollCreateOutcome.moderated,
      );
      expect(
        (await create(pollThread(label: '(草稿)'), tid: '321', uid: 1000)).$1.outcome,
        PollCreateOutcome.unconfirmed,
      );
      expect((await create(pollThread(uid: 1001), tid: '321', uid: 1000)).$1.outcome, PollCreateOutcome.unconfirmed);
    });

    test('an answer without a page is unconfirmed', () async {
      expect((await create('')).$1.outcome, PollCreateOutcome.unconfirmed);
      expect((await create(const {'ok': 0, 'error': 'internal'})).$1.outcome, PollCreateOutcome.unconfirmed);
    });
  });

  group('a report prepared on a fresh thread page (PostReportRepository.prepare)', () {
    /// The reply of `thread_v3_plain.json`, by another member, offered to uid 35 to report.
    const target = PostReportTarget(pid: _plainReplyPid, tid: 9199345, fid: _plainFid, viewerUid: _plainUid);
    final form = reportFormAjax(
      pid: _plainReplyPid,
      hidden: [
        for (final (name, value) in defaultHidden)
          switch (name) {
            'rid' => (name, '$_plainReplyPid'),
            'fid' => (name, '$_plainFid'),
            'handlekey' => (name, 'miscreport$_plainReplyPid'),
            _ => (name, value),
          },
      ],
    );

    (PostReportRepository, List<Uri>) repository(String page, {String? form}) {
      final gets = <Uri>[];
      return (
        PostReportRepository(
          get: (url, {required ajax}) async {
            gets.add(url);
            return PostReportResponse(200, url.path == '/misc.php' ? (form ?? reportFormAjax()) : page);
          },
          post: (_, _) async => throw StateError('no post'),
        ),
        gets,
      );
    }

    Future<PostReportProblem> fails(String page, {PostReportTarget t = target, int uid = _plainUid}) async {
      try {
        await repository(page).$1.prepare(t, uid: uid);
      } on PostReportFailure catch (e) {
        return e.problem;
      }
      fail('prepared');
    }

    test('built: the floor still offered to the account, the thread page asked in JSON mode', () async {
      final (repo, gets) = repository(_raw('thread_v3_plain.json'), form: form);
      final prepared = await repo.prepare(target, uid: _plainUid);
      expect(prepared.target, target);
      expect(gets.first.queryParameters, containsPair('tsdmapp', 'json'));
      expect(gets.first.queryParameters, containsPair('goto', 'findpost'));
      expect(gets.first.queryParameters, containsPair('pid', '$_plainReplyPid'));
      expect(gets.last.path, '/misc.php');
    });

    test('built: the answer dio decoded is carried as its JSON text by the network transport', () async {
      // The thread page as the plugin's JSON, the report dialog as the forum's xml fragment.
      final forum = _Forum(
        (options) => options.uri.path == '/misc.php' ? _html(form) : _api(_raw('thread_v3_plain.json')),
      );
      final prepared = await PostReportRepository.network(_client(forum)).prepare(target, uid: _plainUid);
      expect(prepared.target, target);
      expect(forum.requests, hasLength(2));
      expect(forum.requests.first.uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(forum.requests.first.uri.queryParameters, containsPair('pid', '$_plainReplyPid'));
      expect(forum.requests.last.uri.path, '/misc.php');
      // Another account on the same forum: the decoded answer is still read, the uid compared.
      expect(
        () => PostReportRepository.network(_client(forum)).prepare(target, uid: 36),
        throwsA(isA<PostReportFailure>().having((e) => e.problem, 'problem', PostReportProblem.accountChanged)),
      );
    });

    test('built: another account, a guest, the login prompt', () async {
      expect(await fails(jsonEncode(_plain(uid: 36))), PostReportProblem.accountChanged);
      expect(await fails(jsonEncode(_plain(uid: 0))), PostReportProblem.notLoggedIn);
      expect(await fails(jsonEncode(_messageTo(0))), PostReportProblem.notLoggedIn, reason: 'plugin 2.2.0');
    });

    test('built: the forum message names its account (plugin 2.2.0): a change first, then the message', () async {
      expect(await fails(jsonEncode(_messageTo(36))), PostReportProblem.accountChanged);
      expect(await fails(jsonEncode(_messageTo(_plainUid))), PostReportProblem.forumMessage);
      try {
        await repository(jsonEncode(_messageTo(_plainUid))).$1.prepare(target, uid: _plainUid);
        fail('prepared');
      } on PostReportFailure catch (e) {
        expect(e.problem, PostReportProblem.forumMessage);
        expect(e.message, _memberMessage['message']);
      }
    });

    test('the forum message of plugin 2.1.0 names no account: its document is read as before', () async {
      String withDocument(Map<String, Object?> message, String document) =>
          jsonEncode({...message, 'document': document});
      const text = '<div id="messagetext" class="alert_error"><p>抱歉，本帖要求阅读权限高于 20 才能浏览</p></div>';
      // The member's message: the account from discuz_uid, then the message.
      expect(
        await fails(withDocument(_memberMessage, "<script>var discuz_uid = '$_plainUid';</script>$text")),
        PostReportProblem.forumMessage,
      );
      expect(
        await fails(withDocument(_memberMessage, "<script>var discuz_uid = '36';</script>$text")),
        PostReportProblem.accountChanged,
      );
      // The login prompt of a guest.
      final guest = {..._memberMessage, 'login': 1};
      expect(
        await fails(withDocument(guest, '<div id="messagelogin">$text</div>')),
        PostReportProblem.notLoggedIn,
      );
      // Without its document (the fixtures dropped it; plugin 2.3.0 asked with nodoc=1) the message page is rebuilt
      // from the fields (tsdmAppPageDocument, test_217): the guest's prompt is told; a message of a plugin that
      // names no account is not understood, as a page without one is.
      expect(await fails(_raw('thread_v3_denied_guest.json')), PostReportProblem.notLoggedIn);
      expect(await fails(jsonEncode(_memberMessage)), PostReportProblem.unsupported);
    });

    test('built: a floor gone, the report not offered, another thread or forum', () async {
      expect(
        await fails(jsonEncode(_plain(posts: (p) => {...p, 'pid': p['pid'] == _plainReplyPid ? 1 : p['pid']}))),
        PostReportProblem.noPermission,
      );
      expect(await fails(jsonEncode(_plain(posts: (p) => _can(p, {'report': 0})))), PostReportProblem.noPermission);
      expect(
        await fails(_raw('thread_v3_plain.json'), t: target.copyWith(tid: 1)),
        PostReportProblem.noPermission,
        reason: 'another thread',
      );
      expect(
        await fails(_raw('thread_v3_plain.json'), t: target.copyWith(fid: 3)),
        PostReportProblem.noPermission,
        reason: 'another forum',
      );
      expect(await fails(jsonEncode(_plain(thread: {'fid': 3}))), PostReportProblem.noPermission);
    });

    test('the web page: as before', () async {
      final (repo, gets) = repository(threadPage());
      final prepared = await repo.prepare(reportTarget, uid: viewerUid);
      expect(prepared.target, reportTarget);
      expect(gets.first.queryParameters, containsPair('tsdmapp', 'json'));
      expect(
        await fails(
          threadPage(uid: otherUid),
          t: reportTarget,
          uid: viewerUid,
        ),
        PostReportProblem.accountChanged,
      );
      expect(
        await fails(
          threadPage(floors: ''),
          t: reportTarget,
          uid: viewerUid,
        ),
        PostReportProblem.noPermission,
      );
    });
  });

  group('a draft opened from the draft box (DraftRepository.resolve)', () {
    const entry = DraftEntry(tid: _plainTid, fid: '$_plainFid', title: 'x', forumName: 'y');

    Map<String, dynamic> editable(Map<String, dynamic> p) => p['first'] == 1 ? _can(p, {'edit': 1}) : p;

    Future<DraftEditTarget> resolve(Object? answer, {DraftEntry e = entry, int uid = _plainUid}) =>
        DraftRepository((_) async => answer).resolve(e, uid);

    test('built: the draft, its first floor and the edit link the forum offers on it', () async {
      final target = await resolve(_plain(thread: {'draft': 1}, posts: editable));
      expect(target, (fid: '$_plainFid', tid: _plainTid, pid: '$_plainFirstPid'));
      // The answer as text too, as the production transport hands it over when dio did not decode it.
      expect(
        await resolve(jsonEncode(_plain(thread: {'draft': 1}, posts: editable))),
        (fid: '$_plainFid', tid: _plainTid, pid: '$_plainFirstPid'),
      );
    });

    test('built: no longer a draft, not editable, another thread, another account', () async {
      expect(() => resolve(_plain(posts: editable)), throwsA(isA<FormatException>()));
      expect(() => resolve(_plain(thread: {'draft': 1})), throwsA(isA<FormatException>()), reason: 'can.edit 0');
      expect(
        () => resolve(
          _plain(thread: {'draft': 1}, posts: editable),
          e: const DraftEntry(tid: '1', fid: '2', title: '', forumName: ''),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => resolve(
          _plain(thread: {'draft': 1}, posts: editable),
          e: const DraftEntry(tid: _plainTid, fid: '3', title: '', forumName: ''),
        ),
        throwsA(isA<FormatException>()),
        reason: 'the edit link names forum 2',
      );
      expect(() => resolve(_plain(thread: {'draft': 1}, posts: editable), uid: 36), throwsA(isA<FormatException>()));
      expect(() => resolve(_plain(thread: {'draft': 1}, posts: editable, uid: 0)), throwsA(isA<FormatException>()));
      expect(() => resolve(_memberMessage), throwsA(isA<FormatException>()));
    });

    test('the web page and the answer of an older plugin: parsed as before', () async {
      const e = DraftEntry(tid: '123', fid: '4', title: 'x', forumName: 'y');
      expect(await resolve(draftThread(), e: e, uid: 1000), (fid: '4', tid: '123', pid: '456'));
      final older = _olderAnswer(draftThread());
      expect(await resolve(older, e: e, uid: 1000), (fid: '4', tid: '123', pid: '456'));
      expect(await resolve(jsonEncode(older), e: e, uid: 1000), (fid: '4', tid: '123', pid: '456'));
      expect(() => resolve(draftThread(draft: false), e: e, uid: 1000), throwsA(isA<FormatException>()));
      expect(() => resolve(draftThread(uid: 1001), e: e, uid: 1000), throwsA(isA<FormatException>()));
    });

    test('the draft list is still read from the page', () async {
      final page = await DraftRepository((_) async => draftList()).load(1000);
      expect(page.entries.single.tid, '123');
    });

    test('the production transport hands the answer over and fails on one without a page', () async {
      _use(_Forum.always(_api(_plain(thread: {'draft': 1}, posts: editable))));
      final target = await DraftRepository.network(getIt.get<NetClientProvider>()).resolve(entry, _plainUid);
      expect(target.pid, '$_plainFirstPid');
      // A structured answer is a page without the blocks of the page too (the fixtures dropped them).
      final noDocument = Map<String, dynamic>.from(_plain(thread: {'draft': 1}, posts: editable))..remove('document');
      _use(_Forum.always(_apiAsIs(jsonEncode(noDocument))));
      expect(
        (await DraftRepository.network(getIt.get<NetClientProvider>()).resolve(entry, _plainUid)).pid,
        '$_plainFirstPid',
      );
      _use(_Forum.always(_apiAsIs('{"ok":0,"error":"internal"}')));
      expect(
        () => DraftRepository.network(getIt.get<NetClientProvider>()).resolve(entry, _plainUid),
        throwsA(isA<HttpRequestFailedException>()),
      );
    });
  });
}
