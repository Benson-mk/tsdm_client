/// The forum's app API, plugin 2.4.0: the search results (`schema: 6`), the guide lists (`schema: 7`) and the
/// "my threads" pages (`schema: 9`) answered as structured fields, one row shape for the three.
///
/// The pages are asked in the JSON mode as before, but an answer of plugin 2.4.0 carries every field the app reads:
/// the rows (the thread, its forum, author and last replier, the counts, the flags the states come from, the title
/// style, the excerpt or the reply quoted, one row per reply on the reply pages), the pagination (`page`, `pages`,
/// `has_next`: the pages without a total paginate by `has_next` alone) and, on the search, the id and the total of
/// the search. The readers build the models the pages show ([SearchedThread.fromApi], [LatestThread.fromApi],
/// [MyThread.fromApi], [guideModulesFromApi], [draftPageFromApi]) and never parse the `document` of such an answer;
/// the repositories hand the answer over as a [TsdmAppStructuredPage], and the web page (or an older plugin's
/// answer) as a [TsdmAppWebPage] parsed as before.
///
/// The fixtures `search_v6_*.json`, `guide_v7_*.json` and `mythread_v9_*.json` are answers of the test forum (Discuz
/// X5.0.2 with plugin 2.4.0, 2026-10-21) with their `document` and `head` removed, the search id pinned to 1;
/// `search_v6_results.json`, `guide_v7_new.json` and `mythread_v9_thread.json` keep a `document` on purpose, a
/// garbage one, to prove that path never reads it. `s3_search.json` (plugin 1.3.0) and the `guide_*_x5.html` pages
/// are the old answers, parsed from their document as they always were.
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
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/homepage/utils/guide_index_api.dart';
import 'package:tsdm_client/features/homepage/utils/parse_guide_index.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/latest_thread/utils/guide_page_api.dart';
import 'package:tsdm_client/features/my_thread/bloc/my_thread_bloc.dart';
import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/my_thread/utils/my_thread_page_api.dart';
import 'package:tsdm_client/features/search/bloc/search_bloc.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/features/search/utils/search_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:universal_html/parsing.dart';

import 'draft_fixtures.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// The rows of the answer [name].
List<Map<String, dynamic>> _rows(String name) => (_json(name)['threads'] as List).cast<Map<String, dynamic>>();

/// The row of [tid] in the answer [name].
Map<String, dynamic> _row(String name, int tid) => _rows(name).firstWhere((e) => e['tid'] == tid);

/// The answer [name] with [changes] applied on top (a copy).
Map<String, dynamic> _with(String name, Map<String, Object?> changes) => {..._json(name), ...changes};

/// The forum's unix seconds as the instant the app keeps.
DateTime _at(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

/// The forum's unix seconds as the forum's wall clock (+8, the `timeoffset` of the fixtures), for a time the cards
/// show as a date.
DateTime? _clock(int seconds) => tsdmAppWallClockTime(seconds, 8);

String _page(String name) => File('test/data/$name').readAsStringSync();

/// The body of a web page, as the plugin cut it into `document` before 2.0.0.
String _bodyOf(String html) => RegExp('<body>(.*)</body>', dotAll: true).firstMatch(html)?.group(1) ?? html;

/// One answer of the fake forum.
typedef _Answer = ({String body, bool json, int status});

_Answer _html(String body) => (body: body, json: false, status: 200);

_Answer _api(Object answer, {int status = 200}) =>
    (body: answer is String ? answer : jsonEncode(answer), json: true, status: status);

/// A forum answering every request with [answer] and recording it.
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
    return ResponseBody.fromString(
      a.body,
      a.status,
      headers: {
        Headers.contentTypeHeader: [if (a.json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(
  () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
);

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

bool _asksLean(RequestOptions o) => o.uri.queryParameters['tsdmapp'] == 'json' && o.uri.queryParameters['nodoc'] == '1';

/// A row of the test forum as the tests compare it.
String _view(DraftEntry e) => '${e.tid}|${e.fid}|${e.title}|${e.forumName}';

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

  group('the structured answers are told apart', () {
    test('each page by its type and schema, lean or not; the message of the plugin (login tells it)', () {
      for (final name in ['search_v6_results', 'search_v6_p2', 'search_v6_empty']) {
        expect(searchApiAnswerOf(_raw('$name.json')), isNotNull, reason: name);
        expect(searchApiAnswerOf(_json('$name.json')), isNotNull, reason: '$name as a map');
      }
      for (final name in ['new', 'newthread', 'hot', 'digest', 'sofa', 'my', 'index']) {
        expect(guideApiAnswerOf(_raw('guide_v7_$name.json')), isNotNull, reason: name);
        expect(guideApiAnswerOf(_json('guide_v7_$name.json')), isNotNull, reason: '$name as a map');
      }
      for (final name in ['thread', 'thread_p2', 'reply', 'draft']) {
        expect(myThreadApiAnswerOf(_raw('mythread_v9_$name.json')), isNotNull, reason: name);
        expect(myThreadApiAnswerOf(_json('mythread_v9_$name.json')), isNotNull, reason: '$name as a map');
      }
      expect(_json('search_v6_p2.json'), isNot(contains('document')), reason: 'lean');
      expect(_json('guide_v7_hot.json'), isNot(contains('document')), reason: 'lean');
      expect(_json('mythread_v9_reply.json'), isNot(contains('document')), reason: 'lean');

      // The forum's messages: a guest asked for "my" threads, a guest on the "my threads" page, a search refused.
      expect(guideApiAnswerOf(_raw('guide_v7_guest_my.json')), isNotNull);
      expect(myThreadApiAnswerOf(_raw('mythread_v9_guest.json')), isNotNull);
      final busy = {'ok': 0, 'error': 'message', 'message': '抱歉，您的搜索过于频繁，请稍后再试', 'login': 0, 'uid': 35};
      expect(searchApiAnswerOf(busy), busy);
      expect(searchApiAnswerOf({'ok': 0, 'error': 'message', 'message': 'x', 'schema': 6}), isNotNull);
      expect(guideApiAnswerOf({'ok': 0, 'error': 'message', 'message': 'x', 'schema': 7}), isNotNull);
      expect(myThreadApiAnswerOf({'ok': 0, 'error': 'message', 'message': 'x', 'schema': 9}), isNotNull);
    });

    test('not: another page, a lower schema, an older plugin, the web page, a failed build, the search form', () {
      expect(searchApiAnswerOf(_raw('guide_v7_new.json')), isNull);
      expect(guideApiAnswerOf(_raw('search_v6_results.json')), isNull);
      expect(myThreadApiAnswerOf(_raw('guide_v7_my.json')), isNull);
      expect(searchApiAnswerOf(_raw('forum_v2_fid2_guest.json')), isNull, reason: 'the forum page is schema 2');
      expect(searchApiAnswerOf(_with('search_v6_results.json', {'schema': 5})), isNull);
      expect(guideApiAnswerOf(_with('guide_v7_new.json', {'schema': 6})), isNull);
      expect(myThreadApiAnswerOf(_with('mythread_v9_thread.json', {'schema': 8})), isNull);
      expect(searchApiAnswerOf(_raw('s3_search.json')), isNull, reason: 'plugin 1.3.0: type search without schema');
      expect(searchApiAnswerOf(_raw('s3_search.html')), isNull);
      expect(guideApiAnswerOf(_page('guide_hot_x5.html')), isNull);
      expect(
        guideApiAnswerOf({'ok': 1, 'api': 1, 'type': 'guide', 'document': _bodyOf(_page('guide_hot_x5.html'))}),
        isNull,
      );
      for (final of in [searchApiAnswerOf, guideApiAnswerOf, myThreadApiAnswerOf, latestThreadApiAnswerOf]) {
        expect(of({'ok': 0, 'error': 'internal'}), isNull);
        expect(of({'ok': 0, 'error': 'message', 'message': 'x', 'document': '<p>x</p>'}), isNull);
        expect(of(null), isNull);
        expect(of(''), isNull);
      }
      // The search form page (no search id yet) is answered without a schema: read from its document as before.
      expect(searchApiAnswerOf({'ok': 1, 'api': 1, 'type': 'search', 'page': 1, 'document': '<form></form>'}), isNull);
    });

    test('the latest thread page takes a guide list and the search of 查看新帖, nothing else', () {
      expect(latestThreadApiAnswerOf(_raw('guide_v7_new.json')), isNotNull);
      expect(latestThreadApiAnswerOf(_raw('search_v6_results.json')), isNotNull);
      expect(latestThreadApiAnswerOf(_raw('guide_v7_guest_my.json')), isNotNull);
      expect(latestThreadApiAnswerOf(_raw('mythread_v9_thread.json')), isNull);
      expect(latestThreadApiAnswerOf(_raw('s3_search.json')), isNull);
    });
  });

  group('the search results: searchResultFromApi', () {
    test('every field of the first page; the garbage document is never read', () {
      final raw = _raw('search_v6_results.json');
      expect(raw, contains(r'"document":"<div id=\"wp\">nothing</div>"'), reason: 'the garbage document is there');
      final result = searchResultFromApi(_json('search_v6_results.json'));
      expect(result.currentPage, 1);
      expect(result.totalPages, 11);
      expect(result.count, 211);
      expect(result.data, hasLength(20));

      final first = result.data!.first;
      expect(first.tid, 9199879);
      expect(first.threadID, 9199879);
      expect(first.title, '[转载][BD+GD][230201] 测试歌手 - 多网盘36845 [FLAC]', reason: 'the plain subject, not the html');
      expect(first.url, '$baseUrl/forum.php?mod=viewthread&tid=9199879');
      expect(first.author.name, 'ag_low2');
      expect(first.author.uid, '35');
      expect(first.author.url, '$baseUrl/home.php?mod=space&uid=35');
      expect(first.author.avatarUrl, isNotNull);
      expect(first.publishTime, _clock(1792293941));
      expect(first.forumName, '主機・PC 遊戲');
      expect(first.forumUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=11');

      expect(result.data!.map((e) => e.tid).take(5), [9199879, 9199870, 9199869, 9199864, 9199858]);
      expect(result.data!.last.tid, 9199822);
      expect(result.data!.map((e) => e.title), everyElement(isNot(contains('<strong>'))));
    });

    test('page 2 of 11; the empty result is a page (count 0), not a message; the search id and its paging link', () {
      final p2 = searchResultFromApi(_json('search_v6_p2.json'));
      expect(p2.currentPage, 2);
      expect(p2.totalPages, 11);
      expect(p2.count, 211);
      expect(p2.data!.first.tid, 9199821);
      expect(p2.data!.last.tid, 9199800);

      final empty = searchResultFromApi(_json('search_v6_empty.json'));
      expect(empty.currentPage, 1);
      expect(empty.totalPages, 1);
      expect(empty.count, 0);
      expect(empty.data, isEmpty);

      expect(searchIdOfApi(_json('search_v6_results.json')), '1');
      expect(
        searchResultPageUrl(_json('search_v6_results.json'), 2),
        '$baseUrl/search.php?mod=forum&searchid=1&orderby=lastpost&ascdesc=desc&searchsubmit=yes&page=2',
      );
      expect(searchIdOfApi(_with('search_v6_results.json', {'searchid': 0})), isNull);
      expect(searchResultPageUrl(_with('search_v6_results.json', {'searchid': 0}), 2), isNull);
      // A page without pages: one page.
      expect(searchResultFromApi(_with('search_v6_empty.json', {'pages': 0})).totalPages, 1);
    });

    test('an anonymous author has no uid and no link; a name without a uid links by name; a moved thread; no time', () {
      final row = _row('search_v6_results.json', 9199879);
      final anonymous = SearchedThread.fromApi({...row, 'anonymous': 1, 'author': '', 'authorid': 0});
      expect(anonymous.author.name, '匿名');
      expect(anonymous.author.uid, isNull);
      expect(anonymous.author.url, isEmpty);
      expect(anonymous.author.avatarUrl, isNull);
      // The forum names the author but no uid: linked by name, as the page links such a row.
      final named = SearchedThread.fromApi({...row, 'authorid': 0});
      expect(named.author.name, 'ag_low2');
      expect(named.author.uid, isNull);
      expect(named.author.url, '$baseUrl/home.php?mod=space&username=ag_low2');
      // A moved thread is the row of its target, as the page links its title.
      final moved = SearchedThread.fromApi({...row, 'moved': 9199000});
      expect(moved.tid, 9199000);
      expect(moved.url, '$baseUrl/forum.php?mod=viewthread&tid=9199000');
      expect(SearchedThread.fromApi({...row, 'dateline': 0}).publishTime, isNull);
    });

    test('a row without a thread or a subject is dropped, as the page parser drops a malformed row', () {
      final row = _row('search_v6_results.json', 9199879);
      final rows = [
        {...row, 'tid': 0},
        {...row, 'subject': ''},
        {...row, 'tid': 1},
        'not a row',
      ];
      final result = searchResultFromApi(_with('search_v6_results.json', {'threads': rows}));
      expect(result.data!.map((e) => e.tid), [1]);
      expect(result.count, 211, reason: "the total is the forum's");
    });
  });

  group('the guide lists: latestThreadsFromApi', () {
    final newUrl = guideUrl('new');

    test('最新回复: every field of a row, the next page; the garbage document is never read', () {
      expect(_raw('guide_v7_new.json'), contains(r'"document":"<div id=\"wp\">nothing</div>"'));
      final (threads, next) = latestThreadsFromApi(_json('guide_v7_new.json'), newUrl);
      expect(threads, hasLength(50));
      expect(next, '$newUrl&page=2');

      final first = threads.first;
      expect(first.isValid, isTrue);
      expect(first.threadID, '9199961');
      expect(first.title, '2026年10月20日签到记录贴');
      expect(first.url, '$baseUrl/forum.php?mod=viewthread&tid=9199961');
      expect(first.forumName, 'PS 每日签到验收版');
      expect(first.forumUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=31');
      expect(first.replyCount, 1);
      expect(first.viewCount, 1);
      expect(first.latestReplyAuthor?.name, 'ag_t13');
      expect(first.latestReplyAuthor?.uid, isNull, reason: 'the list pages name no uid for the last replier');
      expect(first.latestReplyAuthor?.url, '$baseUrl/home.php?mod=space&username=ag_t13');
      expect(first.latestReplyTime, _clock(1792505548));
      expect(first.quotedMessage, isNull);
      expect(first.threadAuthor?.name, 'ag_t12');
      expect(first.threadAuthor?.uid, '48');
      expect(first.threadAuthor?.url, '$baseUrl/home.php?mod=space&uid=48');

      expect(threads.map((e) => e.threadID).take(4), ['9199961', '9199954', '9199952', '9199950']);
      // A moved thread is the row of its target, as the page links it.
      expect(_row('guide_v7_new.json', 9199942)['moved'], 9199941);
      expect(threads.map((e) => e.threadID), isNot(contains('9199942')));
      expect(threads.map((e) => e.threadID), contains('9199941'));
    });

    test('the other views: 最新发表, 热门 (one page), 精华 (empty), 抢沙发, and "my" (no total, a next page)', () {
      final (newThreads, nextNew) = latestThreadsFromApi(_json('guide_v7_newthread.json'), guideUrl('newthread'));
      expect(newThreads, hasLength(50));
      expect(newThreads.first.threadID, '9199970');
      expect(nextNew, '${guideUrl('newthread')}&page=2');

      final (hot, nextHot) = latestThreadsFromApi(_json('guide_v7_hot.json'), guideUrl('hot'));
      expect(hot, hasLength(5));
      expect(hot.map((e) => e.threadID).take(4), ['9199670', '9199653', '9199628', '9199611']);
      expect(hot.first.replyCount, 2);
      expect(hot.first.viewCount, 8);
      expect(hot.first.latestReplyAuthor?.name, 'ag_t09');
      expect(nextHot, isNull);

      final (digest, nextDigest) = latestThreadsFromApi(_json('guide_v7_digest.json'), guideUrl('digest'));
      expect(digest, isEmpty);
      expect(nextDigest, isNull);

      final (sofa, nextSofa) = latestThreadsFromApi(_json('guide_v7_sofa.json'), guideUrl('sofa'));
      expect(sofa, hasLength(50));
      expect(sofa.first.replyCount, 0);
      expect(nextSofa, isNull);

      final my = _json('guide_v7_my.json');
      expect(my['pages'], 0, reason: 'the page has no total');
      expect(my['has_next'], 1);
      final (mine, nextMine) = latestThreadsFromApi(my, guideUrl('my'));
      expect(mine, hasLength(50));
      expect(mine.first.threadID, '9199982');
      expect(mine.first.threadAuthor?.uid, '35');
      expect(nextMine, '${guideUrl('my')}&page=2');
    });

    test('the page asked for page 2 names page 3; a url with other parameters keeps them', () {
      expect(tsdmAppListPageUrl('$newUrl&page=2', 3), '$newUrl&page=3');
      expect(
        tsdmAppListPageUrl('$baseUrl/forum.php?mod=guide&view=my&type=reply', 2),
        '$baseUrl/forum.php?mod=guide&view=my&type=reply&page=2',
      );
      final (_, next) = latestThreadsFromApi(_with('guide_v7_new.json', {'page': 2}), '$newUrl&page=2');
      expect(next, '$newUrl&page=3');
      final (_, last) = latestThreadsFromApi(
        _with('guide_v7_new.json', {'page': 12, 'has_next': 0}),
        '$newUrl&page=12',
      );
      expect(last, isNull);
    });

    test('a reply row (pid) links the reply and quotes it; an anonymous author and last replier', () {
      final row = _row('guide_v7_my.json', 9199936);
      final reply = LatestThread.fromApi({...row, 'pid': 4321, 'summary': 'quoted\nreply'});
      expect(reply.url, '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=9199936&pid=4321');
      expect(reply.quotedMessage, 'quoted\nreply');
      expect(reply.threadID, '9199936');

      final anonymous = LatestThread.fromApi({...row, 'anonymous': 1, 'author': '', 'authorid': 0});
      expect(anonymous.threadAuthor?.name, '匿名');
      expect(anonymous.threadAuthor?.uid, isNull);
      expect(anonymous.threadAuthor?.url, isEmpty);
      final lastAnonymous = LatestThread.fromApi({...row, 'lastposter': ''});
      expect(lastAnonymous.latestReplyAuthor?.name, '匿名');
      expect(lastAnonymous.latestReplyAuthor?.url, isEmpty);
    });

    test('a row without a thread or a subject is dropped, as the page parser drops a malformed row', () {
      final row = _row('guide_v7_new.json', 9199961);
      final rows = [
        {...row, 'tid': 0},
        {...row, 'subject': ''},
        {...row, 'tid': 1},
      ];
      final (threads, _) = latestThreadsFromApi(_with('guide_v7_new.json', {'threads': rows}), newUrl);
      expect(threads.map((e) => e.threadID), ['1']);
      final (search, _) = latestThreadsFromApi(_with('search_v6_results.json', {'threads': rows}), newUrl);
      expect(search.map((e) => e.threadID), ['1']);
    });

    test('the forum message (the guide switched off, a guest asking "my") is an empty list, as the page parsed to', () {
      final (threads, next) = latestThreadsFromApi(_json('guide_v7_guest_my.json'), guideUrl('my'));
      expect(threads, isEmpty);
      expect(next, isNull);
    });

    test('查看新帖: the search results on the latest thread page, the excerpt quoted, the search paging link', () {
      const url = '$baseUrl/search.php?mod=forum&srchfrom=86400&searchsubmit=yes';
      final (threads, next) = latestThreadsFromApi(_json('search_v6_results.json'), url);
      expect(threads, hasLength(20));
      expect(next, '$baseUrl/search.php?mod=forum&searchid=1&orderby=lastpost&ascdesc=desc&searchsubmit=yes&page=2');
      final first = threads.first;
      expect(first.threadID, '9199879');
      expect(first.quotedMessage, startsWith('【百度网盘】\n网盘链接 Link：'));
      expect(first.threadAuthor?.name, 'ag_low2');
      expect(first.threadAuthor?.uid, '35');
      expect(first.latestReplyAuthor?.name, 'ag_low2');
      expect(first.latestReplyTime, _clock(1792293941));
      expect(first.forumName, '主機・PC 遊戲');
      expect(first.forumUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=11');

      // The person and the time shown are the author and the publish time, as the search layout prints them
      // (`dateline - author`), not the last reply: the row whose last reply is later than its publish time.
      final row = _row('search_v6_results.json', 9199751);
      expect(row['lastpost'], isNot(row['dateline']));
      final replied = threads.singleWhere((e) => e.threadID == '9199751');
      expect(replied.latestReplyTime, _clock(1792076503), reason: 'the publish time (dateline), not lastpost');
      expect(replied.latestReplyAuthor?.name, 'ag_low');
      expect(replied.latestReplyAuthor?.uid, '31');
      expect(replied.threadAuthor?.name, 'ag_low');
      expect(replied.replyCount, 7);
      final other = LatestThread.fromSearchApi({...row, 'lastposter': 'someone_else', 'lastpost': 1792300000});
      expect(other.latestReplyAuthor?.name, 'ag_low', reason: 'the author, not the last poster');
      expect(other.latestReplyTime, _clock(1792076503));
      // The guide builder of the same row would show the last reply.
      final asGuide = LatestThread.fromApi(row);
      expect(asGuide.latestReplyTime, _clock(1792177148));

      final (last, nextLast) = latestThreadsFromApi(_with('search_v6_results.json', {'page': 11, 'has_next': 0}), url);
      expect(last, hasLength(20));
      expect(nextLast, isNull);
    });
  });

  group('the guide index: guideModulesFromApi', () {
    test('the four modules in the page order, each row; the empty module keeps the page sentence', () {
      final modules = guideModulesFromApi(_json('guide_v7_index.json'));
      expect(modules.map((e) => e.view), ['hot', 'digest', 'new', 'newthread']);
      expect(modules.map((e) => e.title), ['最新热门', '最新精华', '最新回复', '最新发表']);
      expect(modules.map((e) => e.moreUrl), [
        '$baseUrl/forum.php?mod=guide&view=hot',
        '$baseUrl/forum.php?mod=guide&view=digest',
        '$baseUrl/forum.php?mod=guide&view=new',
        '$baseUrl/forum.php?mod=guide&view=newthread',
      ]);
      expect(modules.map((e) => e.items.length), [5, 0, 30, 30]);
      expect(modules.map((e) => e.emptyMessage), [null, '暂时还没有帖子', null, null]);

      final hot = modules[0].items.first;
      expect(hot.tid, '9199670');
      expect(hot.title, '[百度网盘] 重载测试 940498');
      expect(hot.url, '$baseUrl/forum.php?mod=viewthread&tid=9199670');
      expect(hot.fid, '11');
      expect(hot.forumName, '主機・PC 遊戲');
      expect(hot.extra, '3人参与');
      expect(hot.highlighted, isFalse);

      final latest = modules[2].items.first;
      expect(latest.tid, '9199961');
      expect(latest.extra, '昨天 22:12', reason: 'the last reply as the page shows it');
      expect(latest.highlighted, isTrue, reason: 'a colored title');

      final newest = modules[3].items.first;
      expect(newest.tid, '9199970');
      expect(newest.extra, isNull);
      expect(newest.highlighted, isTrue);

      // The same shape the web page gives.
      final web = parseGuideIndex(parseHtmlDocument(_page('guide_index_x5.html')));
      expect(web.map((e) => e.view), modules.map((e) => e.view));
      expect(modules.first.toMap().keys, web.first.toMap().keys);
      expect(modules[0].items.first.toMap().keys, web.first.items.first.toMap().keys);
    });

    test('a row: a moved thread is its target, no forum without a fid, no extra when blank, a style highlights', () {
      final json = _json('guide_v7_index.json');
      final modules = (json['modules'] as List).cast<Map<String, dynamic>>();
      final row = (modules[0]['threads'] as List).cast<Map<String, dynamic>>().first;
      List<GuideItem> items(Map<String, dynamic> r) => guideModulesFromApi({
        ...json,
        'modules': [
          {
            ...modules[0],
            'threads': [r],
          },
        ],
      }).single.items;
      expect(items({...row, 'moved': 42}).single.tid, '42');
      final bare = items({...row, 'fid': 0, 'forum': '', 'extra': ' '}).single;
      expect(bare.fid, isNull);
      expect(bare.forumName, isNull);
      expect(bare.extra, isNull);
      const plain = {'bold': 0, 'italic': 0, 'underline': 0, 'color': '', 'bgcolor': ''};
      expect(
        items({
          ...row,
          'style': {...plain, 'bold': 1},
        }).single.highlighted,
        isTrue,
      );
      expect(
        items({
          ...row,
          'style': {...plain, 'bgcolor': '#FFFFCC'},
        }).single.highlighted,
        isTrue,
      );
      expect(items({...row, 'style': plain}).single.highlighted, isFalse);
      expect(items({...row, 'style': null}).single.highlighted, isFalse);
      expect(
        items({...row, 'subject': ''}),
        isEmpty,
        reason: 'a row without a title is skipped, as the page parser skips it',
      );
      expect(items({...row, 'tid': 0}), isEmpty, reason: 'a row without a thread the same');
      // A module that names no view (nothing to open) is skipped, as the page parser skips a header without a link.
      expect(
        guideModulesFromApi({
          ...json,
          'modules': [
            {...modules[0], 'view': ''},
          ],
        }),
        isEmpty,
      );
      expect(guideModulesFromApi(_json('guide_v7_guest_my.json')), isEmpty, reason: 'the message');
    });
  });

  group('the "my threads" pages: myThreadsFromApi', () {
    test('the threads: every field, a draft marked, the next page; the garbage document is never read', () {
      expect(_raw('mythread_v9_thread.json'), contains(r'"document":"<div id=\"wp\">nothing</div>"'));
      final json = _json('mythread_v9_thread.json');
      expect(json['pages'], 0, reason: 'the page has no total');
      expect(json['has_next'], 1);
      final (threads, next) = myThreadsFromApi(json, myThreadThreadUrl);
      expect(threads, hasLength(20));
      expect(next, '$myThreadThreadUrl&page=2');

      final draft = threads.first;
      expect(draft.threadID, '9199982');
      expect(draft.title, 'tsdmapp 2.4.0 草稿 00000');
      expect(draft.url, '$baseUrl/forum.php?mod=viewthread&tid=9199982');
      expect(draft.forumName, '📢 公告 & 新手報到');
      expect(draft.forumUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=2');
      expect(draft.replyCount, 0);
      expect(draft.viewCount, 0);
      expect(draft.latestReplyAuthor?.name, 'ag_low2');
      expect(draft.latestReplyAuthor?.uid, isNull);
      expect(draft.latestReplyAuthor?.url, '$baseUrl/home.php?mod=space&username=ag_low2');
      expect(draft.latestReplyTime, _at(1700000000), reason: 'the fixture tool pins the fixture-made draft');
      expect(draft.quotedMessage, isNull);
      expect(draft.stateSet, {ThreadStateModel.draft}, reason: 'displayorder -4: the page marks it 草稿箱');

      final second = threads[1];
      expect(second.threadID, '9199936');
      expect(second.stateSet, isEmpty);
      expect(second.viewCount, 3);
      expect(second.latestReplyTime, _at(1792445974));

      expect(myThreadApiViewerUid(json), 35);
      expect(myThreadApiOwnerUid(json), 35);
    });

    test('page 2 names page 3', () {
      final (threads, next) = myThreadsFromApi(_json('mythread_v9_thread_p2.json'), '$myThreadThreadUrl&page=2');
      expect(threads, hasLength(20));
      expect(threads.first.threadID, '9199876');
      expect(next, '$myThreadThreadUrl&page=3');
    });

    test('the replies: one row per reply, linked to the reply and quoting it', () {
      final (replies, next) = myThreadsFromApi(_json('mythread_v9_reply.json'), myThreadReplyUrl);
      expect(replies, hasLength(16));
      expect(next, '$myThreadReplyUrl&page=2');
      final first = replies.first;
      expect(first.threadID, '9199341');
      expect(first.title, 'TM目標主題 954975');
      expect(first.url, '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=9199341&pid=3925');
      expect(first.quotedMessage, 'TM M7 954975');
      expect(first.replyCount, 6);
      expect(first.viewCount, 14);
      expect(first.forumName, '繪圖・插畫');
      expect(first.forumUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=12');
      expect(first.latestReplyAuthor?.name, 'ag_low2');
      expect(first.latestReplyTime, _at(1790677985));
      expect(first.stateSet, isEmpty);
      expect(replies[1].threadID, '9199341');
      expect(replies[1].url, endsWith('&pid=3921'));
      expect(replies[1].quotedMessage, 'TM M3 954975');
      expect(
        replies.map((e) => e.threadID).toSet().length,
        lessThan(16),
        reason: 'several replies of a thread, a row each',
      );
    });

    test('the states from the flags, a moved thread, an anonymous last replier', () {
      final row = _row('mythread_v9_thread.json', 9199936);
      final flagged = MyThread.fromApi({...row, 'closed': 1, 'digest': 1, 'attachment': 2, 'special': 1});
      expect(flagged.stateSet, {
        ThreadStateModel.closed,
        ThreadStateModel.digested,
        ThreadStateModel.pictureAttached,
        ThreadStateModel.poll,
      });
      final moved = MyThread.fromApi({...row, 'moved': 9199000});
      expect(moved.threadID, '9199000');
      expect(moved.url, '$baseUrl/forum.php?mod=viewthread&tid=9199000');
      expect(moved.stateSet, {ThreadStateModel.closed});
      expect(moved.replyCount, 0);
      final anonymous = MyThread.fromApi({...row, 'lastposter': ''});
      expect(anonymous.latestReplyAuthor?.name, '匿名');
      expect(anonymous.latestReplyAuthor?.url, isEmpty);
    });

    test('a row without a thread or a subject is dropped, as the page parser drops a malformed row', () {
      final row = _row('mythread_v9_thread.json', 9199936);
      final rows = [
        {...row, 'tid': 0},
        {...row, 'subject': ''},
        {...row, 'tid': 1},
      ];
      final (threads, next) = myThreadsFromApi(_with('mythread_v9_thread.json', {'threads': rows}), myThreadThreadUrl);
      expect(threads.map((e) => e.threadID), ['1']);
      expect(next, '$myThreadThreadUrl&page=2');
    });

    test('the guest message is an empty list, as the page parsed to; it names no account', () {
      final json = _json('mythread_v9_guest.json');
      final (threads, next) = myThreadsFromApi(json, myThreadThreadUrl);
      expect(threads, isEmpty);
      expect(next, isNull);
      expect(myThreadApiViewerUid(json), isNull);
      expect(myThreadApiOwnerUid(json), isNull);
    });
  });

  group('the draft box: draftPageFromApi and DraftRepository.load', () {
    test('the drafts of the account, no first floor needed; the next page', () {
      final page = draftPageFromApi(_json('mythread_v9_draft.json'), page: 1, uid: 35);
      expect(page.entries.map(_view), ['9199982|2|tsdmapp 2.4.0 草稿 00000|📢 公告 & 新手報到']);
      expect(page.entries.single.url, '$baseUrl/forum.php?mod=viewthread&tid=9199982');
      expect(page.nextPage, isNull);
      expect(draftPageFromApi(_with('mythread_v9_draft.json', {'has_next': 1}), page: 1, uid: 35).nextPage, 2);
      expect(
        draftPageFromApi(_with('mythread_v9_draft.json', {'has_next': 1, 'page': 2}), page: 2, uid: 35).nextPage,
        3,
      );
      expect(
        draftPageFromApi(_with('mythread_v9_draft.json', {'threads': <Object?>[]}), page: 1, uid: 35).entries,
        isEmpty,
      );
    });

    test("only the draft filter of the account's own list; a row must name its thread, forum and subject", () {
      final draft = _json('mythread_v9_draft.json');
      expect(
        () => draftPageFromApi(_json('mythread_v9_thread.json'), page: 1, uid: 35),
        throwsFormatException,
        reason: 'the thread list, not the drafts',
      );
      expect(
        () => draftPageFromApi(
          {
            ...draft,
            'owner': {'uid': 36, 'username': 'other'},
          },
          page: 1,
          uid: 35,
        ),
        throwsFormatException,
      );
      expect(() => draftPageFromApi({...draft, 'view': 'we'}, page: 1, uid: 35), throwsFormatException);
      expect(() => draftPageFromApi({...draft, 'kind': 'thread'}, page: 1, uid: 35), throwsFormatException);
      expect(() => draftPageFromApi({...draft, 'filter': ''}, page: 1, uid: 35), throwsFormatException);
      final row = _rows('mythread_v9_draft.json').single;
      for (final bad in [
        {...row, 'tid': 0},
        {...row, 'fid': 0},
        {...row, 'subject': ' '},
      ]) {
        expect(
          () => draftPageFromApi(
            {
              ...draft,
              'threads': [bad],
            },
            page: 1,
            uid: 35,
          ),
          throwsFormatException,
        );
      }
    });

    test(
      'through the repository: the account checked, a guest or another account expired, the old page as before',
      () async {
        final repo = DraftRepository((_) async => _json('mythread_v9_draft.json'));
        expect((await repo.load(35)).entries.single.tid, '9199982');
        await expectLater(repo.load(36), throwsFormatException);
        await expectLater(repo.load(0), throwsFormatException);
        final guest = DraftRepository((_) async => _raw('mythread_v9_guest.json'));
        await expectLater(guest.load(35), throwsFormatException);
        // The answer as text: decoded the same.
        expect((await DraftRepository((_) async => _raw('mythread_v9_draft.json')).load(35)).entries, hasLength(1));

        // The web page of the draft box, and an older plugin's answer carrying it, parse as before.
        final html = draftList(uid: 35, next: 2);
        final web = DraftRepository((_) async => html);
        final old = DraftRepository(
          (_) async => jsonEncode({
            'ok': 1,
            'api': 1,
            'type': 'mythread',
            'head': "<script>var discuz_uid = '35';</script>",
            'document': _bodyOf(html),
          }),
        );
        for (final (label, r) in [('the web page', web), ('an older plugin', old)]) {
          final page = await r.load(35);
          expect(page.entries.map(_view), ['123|4|Synthetic draft 123|Test forum'], reason: label);
          expect(page.nextPage, 2, reason: label);
        }
      },
    );
  });

  group('the repositories and the blocs', () {
    _Answer searchAnswer(RequestOptions o) =>
        _api(_raw(o.uri.queryParameters['page'] == '2' ? 'search_v6_p2.json' : 'search_v6_results.json'));

    test('the search: the results from the fields, the search id kept for the next page, lean requests', () async {
      final forum = _Forum(searchAnswer);
      _use(forum);
      final repo = SearchRepository();
      final first = _right(await repo.searchWithParameters(keyword: '网盘', fid: '0', uid: '0', pageNumber: 1).run());
      expect(first.count, 211);
      expect(first.currentPage, 1);
      expect(first.data, hasLength(20));
      expect(forum.requests.single.uri.queryParameters, containsPair('srchtxt', '网盘'));
      expect(forum.requests.every(_asksLean), isTrue);

      final second = _right(await repo.searchWithParameters(keyword: '网盘', fid: '0', uid: '0', pageNumber: 2).run());
      expect(second.currentPage, 2);
      expect(second.data!.first.tid, 9199821);
      expect(forum.requests, hasLength(2));
      expect(forum.requests.last.uri.queryParameters, containsPair('searchid', '1'), reason: 'the id of the answer');
      expect(forum.requests.last.uri.queryParameters, containsPair('page', '2'));
      expect(forum.requests.last.uri.queryParameters, isNot(contains('srchtxt')));
    });

    test('the search without a result is a result (count 0); the forum refusal is its message', () async {
      _use(_Forum.always(_api(_raw('search_v6_empty.json'))));
      final empty = _right(
        await SearchRepository().searchWithParameters(keyword: 'zzqq', fid: '0', uid: '0', pageNumber: 1).run(),
      );
      expect(empty.count, 0);
      expect(empty.data, isEmpty);
      expect(empty.totalPages, 1);

      final refusals = [
        ('too frequent', {'ok': 0, 'error': 'message', 'message': '抱歉，您的搜索过于频繁，请稍后再试', 'login': 0, 'uid': 35}),
        ('expired', {'ok': 0, 'error': 'message', 'message': '抱歉，指定的搜索不存在或已过期', 'schema': 6}),
        ('a guest', {'ok': 0, 'error': 'message', 'message': '请先登录', 'login': 1, 'uid': 0}),
      ];
      for (final (label, message) in refusals) {
        _use(_Forum.always(_api(message)));
        final result = await SearchRepository()
            .searchWithParameters(keyword: 'x', fid: '0', uid: '0', pageNumber: 1)
            .run();
        expect(result.isLeft(), isTrue, reason: label);
        expect(
          result.getLeft().toNullable(),
          isA<ServerRespondedErrorException>().having((e) => e.message, 'message', message['message']),
          reason: label,
        );
      }
      // The old rule kept: a "没有找到" message is an empty result still.
      _use(_Forum.always(_api({'ok': 0, 'error': 'message', 'message': '没有找到匹配结果', 'login': 0, 'uid': 35})));
      final none = _right(
        await SearchRepository().searchWithParameters(keyword: 'x', fid: '0', uid: '0', pageNumber: 1).run(),
      );
      expect(none.data, isEmpty);
      expect(none.count, 0);
    });

    test('the search bloc on the structured results: the pages and the switches', () async {
      _use(_Forum(searchAnswer));
      final bloc = SearchBloc(searchRepository: SearchRepository())
        ..add(const SearchRequested(keyword: '网盘', fid: '0', uid: '0', pageNumer: 1));
      var state = await bloc.stream.firstWhere(
        (s) => s.status == SearchStatus.success || s.status == SearchStatus.failed,
      );
      expect(state.status, SearchStatus.success);
      expect(state.searchResult?.count, 211);
      expect(state.searchResult?.data, hasLength(20));
      expect(state.pageNumber, 1);
      expect(state.hasNextPage, isTrue);
      expect(state.hasPreviousPage, isFalse);

      bloc.add(SearchGotoNextPageRequested());
      state = await bloc.stream.firstWhere((s) => s.status == SearchStatus.success && s.pageNumber == 2);
      expect(state.searchResult?.currentPage, 2);
      expect(state.searchResult?.data?.first.tid, 9199821);
      expect(state.hasPreviousPage, isTrue);
      expect(state.hasNextPage, isTrue);
      await bloc.close();
    });

    test('an older plugin (no schema) and the web page: the search parsed from its document as before', () async {
      final raw = _raw('s3_search.json');
      expect(raw, isNot(contains('"schema"')));
      final web = SearchResult.fromDocument(tsdmAppPageDocument(raw));
      expect(web.data, isNotEmpty);

      _use(_Forum.always(_api(raw)));
      final old = _right(
        await SearchRepository().searchWithParameters(keyword: 'x', fid: '0', uid: '0', pageNumber: 1).run(),
      );
      expect(old.toMap(), web.toMap());

      _use(_Forum.always(_html(_raw('s3_search.html'))));
      final page = _right(
        await SearchRepository().searchWithParameters(keyword: 'x', fid: '0', uid: '0', pageNumber: 1).run(),
      );
      expect(page.data!.map((e) => e.tid), web.data!.map((e) => e.tid));
      expect(page.count, web.count);
    });

    test(
      'the latest thread page: the guide list from the fields, then the next page; the web page as before',
      () async {
        final forum = _Forum(
          (o) => _api(
            o.uri.queryParameters['page'] == '2' ? _with('guide_v7_new.json', {'page': 2}) : _raw('guide_v7_new.json'),
          ),
        );
        _use(forum);
        final url = guideUrl('new');
        expect(_right(await LatestThreadRepository().fetchPage(url).run()), isA<TsdmAppStructuredPage>());

        final bloc = LatestThreadBloc(latestThreadRepository: LatestThreadRepository())
          ..add(LatestThreadRefreshRequested(url));
        var state = await bloc.stream.firstWhere((s) => s.status != LatestThreadStatus.loading);
        expect(state.status, LatestThreadStatus.success);
        expect(state.threadList, hasLength(50));
        expect(state.threadList.first.threadID, '9199961');
        expect(state.nextPageUrl, '$url&page=2');

        bloc.add(LatestThreadLoadMoreRequested());
        state = await bloc.stream.firstWhere((s) => s.pageNumber == 2);
        expect(state.threadList, hasLength(100));
        expect(state.nextPageUrl, '$url&page=3', reason: 'the page the forum answered, as its 下一页 link counted');
        expect(forum.requests, hasLength(3));
        expect(forum.requests.last.uri.queryParameters, containsPair('page', '2'));
        expect(forum.requests.every(_asksLean), isTrue);
        await bloc.close();

        // The guest message: an empty page, not a failure, as before.
        _use(_Forum.always(_api(_raw('guide_v7_guest_my.json'))));
        final guest = LatestThreadBloc(latestThreadRepository: LatestThreadRepository())
          ..add(LatestThreadRefreshRequested(guideUrl('my')));
        final guestState = await guest.stream.firstWhere((s) => s.status != LatestThreadStatus.loading);
        await guest.close();
        expect(guestState.status, LatestThreadStatus.success);
        expect(guestState.threadList, isEmpty);

        // The web page, and an older plugin's answer carrying it, are the document parsed as before.
        final html = _page('guide_hot_x5.html');
        final ids = parseHtmlDocument(
          html,
        ).querySelectorAll('tbody[id^="normalthread_"]').map(LatestThread.fromTBody).map((e) => e.threadID).toList();
        expect(ids, isNotEmpty);
        final answers = [
          ('the web page', _html(html)),
          ('plugin 1.6.0', _api({'ok': 1, 'api': 1, 'type': 'guide', 'document': _bodyOf(html)})),
        ];
        for (final (label, answer) in answers) {
          _use(_Forum.always(answer));
          expect(
            _right(await LatestThreadRepository().fetchPage(guideUrl('hot')).run()),
            isA<TsdmAppWebPage>(),
            reason: label,
          );
          final b = LatestThreadBloc(latestThreadRepository: LatestThreadRepository())
            ..add(LatestThreadRefreshRequested(guideUrl('hot')));
          final s = await b.stream.firstWhere((s) => s.status != LatestThreadStatus.loading);
          await b.close();
          expect(s.status, LatestThreadStatus.success, reason: label);
          expect(s.threadList.map((e) => e.threadID), ids, reason: label);
        }
      },
    );

    test('the "my threads" page: both tabs from the fields, the next pages; the old answers as before', () async {
      final forum = _Forum(
        (o) =>
            _api(_raw(o.uri.queryParameters['type'] == 'reply' ? 'mythread_v9_reply.json' : 'mythread_v9_thread.json')),
      );
      _use(forum);
      final bloc = MyThreadBloc(myThreadRepository: MyThreadRepository())..add(MyThreadLoadInitialDataRequested());
      final state = await bloc.stream.firstWhere((s) => s.status != MyThreadStatus.loading);
      await bloc.close();
      expect(state.status, MyThreadStatus.success);
      expect(state.threadList, hasLength(20));
      expect(state.replyList, hasLength(16));
      expect(state.nextThreadPageUrl, '$myThreadThreadUrl&page=2');
      expect(state.nextReplyPageUrl, '$myThreadReplyUrl&page=2');
      expect(state.threadList.first.stateSet, contains(ThreadStateModel.draft));
      expect(state.replyList.first.quotedMessage, 'TM M7 954975');
      expect(forum.requests, hasLength(2));
      expect(forum.requests.every(_asksLean), isTrue);

      // The guest: the message is a page (an empty one, as before).
      _use(_Forum.always(_api(_raw('mythread_v9_guest.json'))));
      expect(_right(await MyThreadRepository().fetchPage(myThreadThreadUrl).run()), isA<TsdmAppStructuredPage>());
      final guest = MyThreadBloc(myThreadRepository: MyThreadRepository())..add(MyThreadLoadInitialDataRequested());
      final guestState = await guest.stream.firstWhere((s) => s.status != MyThreadStatus.loading);
      await guest.close();
      expect(guestState.status, MyThreadStatus.success);
      expect(guestState.threadList, isEmpty);
      expect(guestState.replyList, isEmpty);

      // An older plugin's answer, and the web page: the document parsed as before.
      final html = draftList(uid: 35);
      for (final answer in [
        _html(html),
        _api({'ok': 1, 'api': 1, 'type': 'mythread', 'document': _bodyOf(html)}),
      ]) {
        _use(_Forum.always(answer));
        final old = _right(await MyThreadRepository().fetchPage(myThreadThreadUrl).run());
        expect(old, isA<TsdmAppWebPage>());
        expect((old as TsdmAppWebPage).document.querySelector('form#delform'), isNotNull);
      }
    });

    test('the guide index: the modules from the fields; the web page as before; the message is no module', () async {
      final forum = _Forum.always(_api(_raw('guide_v7_index.json')));
      _use(forum);
      final modules = _right(await const GuideIndexRepository().fetchGuideIndex().run());
      expect(modules.map((e) => e.view), ['hot', 'digest', 'new', 'newthread']);
      expect(modules[2].items, hasLength(30));
      expect(forum.requests.single.uri.queryParameters, containsPair('view', 'index'));
      expect(forum.requests.every(_asksLean), isTrue);

      final html = _page('guide_index_x5.html');
      final web = parseGuideIndex(parseHtmlDocument(html));
      expect(web, hasLength(4));
      for (final answer in [
        _html(html),
        _api({'ok': 1, 'api': 1, 'type': 'guide', 'document': _bodyOf(html)}),
      ]) {
        _use(_Forum.always(answer));
        final old = _right(await const GuideIndexRepository().fetchGuideIndex().run());
        expect(old.map((e) => e.toMap()), web.map((e) => e.toMap()));
      }

      _use(_Forum.always(_api(_raw('guide_v7_guest_my.json'))));
      expect(_right(await const GuideIndexRepository().fetchGuideIndex().run()), isEmpty);
    });

    test('the draft box through the network: the list from the fields, the draft list asked lean', () async {
      final forum = _Forum.always(_api(_raw('mythread_v9_draft.json')));
      _use(forum);
      final page = await DraftRepository.network(getIt.get<NetClientProvider>()).load(35);
      expect(page.entries.map(_view), ['9199982|2|tsdmapp 2.4.0 草稿 00000|📢 公告 & 新手報到']);
      expect(forum.requests.single.uri.queryParameters, containsPair('filter', 'save'));
      expect(forum.requests.every(_asksLean), isTrue);
      await expectLater(DraftRepository.network(getIt.get<NetClientProvider>()).load(36), throwsFormatException);
    });

    test('an answer without a page is a failed request, as before', () async {
      _use(_Forum.always(_api({'ok': 0, 'error': 'internal'})));
      expect((await LatestThreadRepository().fetchPage(guideUrl('new')).run()).isLeft(), isTrue);
      expect((await MyThreadRepository().fetchPage(myThreadThreadUrl).run()).isLeft(), isTrue);
      expect((await const GuideIndexRepository().fetchGuideIndex().run()).isLeft(), isTrue);
      final search = await SearchRepository()
          .searchWithParameters(keyword: 'x', fid: '0', uid: '0', pageNumber: 1)
          .run();
      expect(search.getLeft().toNullable(), isA<HttpRequestFailedException>());
    });
  });
}
