/// The forum's app API, plugin 2.0.0: the forum page answered as structured fields (`schema: 2`).
///
/// The page (`forum.php?mod=forumdisplay&fid=…`) is asked in the JSON mode as before, but an answer of plugin 2.0.0
/// carries every field the app reads: the forum, its threads (sticky ones included, in the forum's order), its
/// subforums, the type and sort lists, the fixed filter menus, the pagination and the poll offer. The app builds
/// [ForumPageData] from them ([forumPageFromApi], [NormalThread.fromApi], [Forum.fromApi]) and never parses the
/// `document` of such an answer. An older plugin's answer (no `schema`) and the web page are parsed as before.
///
/// The fixtures `forum_v2_*.json` are answers of the test forum (Discuz X5.0.2 with plugin 2.0.0, 2026-10-20) with
/// their `document` and `head` removed: the schema 2 path must not need them. `forum_v2_fid2.json` keeps a `document`
/// on purpose, a garbage one, to prove that path never reads it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// The thread row of [tid] in the answer [name].
Map<String, dynamic> _row(String name, int tid) =>
    (_json(name)['threads'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['tid'] == tid);

/// [NormalThread.fromApi] of the row of [tid] in the answer [name], with the forum's type prefix unless [typePrefix].
NormalThread _thread(String name, int tid, {int? typePrefix}) {
  final json = _json(name);
  return NormalThread.fromApi(
    _row(name, tid),
    fid: (json['forum'] as Map<String, dynamic>)['fid'] as int,
    typePrefix: typePrefix ?? (json['types'] as Map<String, dynamic>)['prefix'] as int,
  );
}

/// The forum's unix seconds as the forum shows them (its time zone is +8).
String _forumClock(DateTime? time) => time == null
    ? '-'
    : DateTime.fromMillisecondsSinceEpoch(
        time.millisecondsSinceEpoch,
        isUtc: true,
      ).add(const Duration(hours: 8)).yyyyMMDDHHMMSS();

/// A forum answering every request with [body] served as [contentType].
final class _Forum implements HttpClientAdapter {
  _Forum(this.body, {this.contentType = 'application/json; charset=utf-8'});

  final String body;
  final String contentType;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The forum page of fid [fid] fetched from a forum answering [body].
Future<Either<AppException, ForumPageData>> _fetch(
  String body, {
  String fid = '2',
  String contentType = 'application/json; charset=utf-8',
}) async {
  final forum = _Forum(body, contentType: contentType);
  getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  );
  return ForumRepository().fetchForum(fid: fid, filterState: const FilterState()).run();
}

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

  group('forumApiAnswerOf tells the structured answers apart', () {
    test('schema 2: the structured page, and the message of the plugin (login tells it)', () {
      expect(forumApiAnswerOf(_raw('forum_v2_fid2.json')), isNotNull);
      expect(forumApiAnswerOf(_json('forum_v2_fid13.json')), isNotNull, reason: 'decoded by dio already');
      expect(forumApiAnswerOf(_raw('forum_v2_fid26_denied.json')), isNotNull);
      expect(forumApiAnswerOf(_raw('forum_v2_fid29_guest.json')), isNotNull);
      expect(forumApiAnswerOf('{"ok":0,"error":"message","message":"x","schema":2}'), isNotNull);
    });

    test('everything else is read from its document as before', () {
      // An older plugin: no schema, its message without login.
      expect(forumApiAnswerOf(_raw('forum_fid2.json')), isNull);
      expect(forumApiAnswerOf(_raw('forum_denied.json')), isNull);
      expect(forumApiAnswerOf('{"ok":1,"type":"forum","schema":1,"document":""}'), isNull);
      expect(forumApiAnswerOf('{"ok":0,"error":"internal"}'), isNull);
      expect(forumApiAnswerOf('{"ok":0,"error":"unknown","schema":2}'), isNull);
      expect(forumApiAnswerOf('<html><body>page</body></html>'), isNull);
      expect(forumApiAnswerOf(''), isNull);
      expect(forumApiAnswerOf(null), isNull);
    });
  });

  group('forumPageFromApi builds the page from the fields', () {
    test('a forum page: every field', () {
      final page = forumPageFromApi(_json('forum_v2_fid2.json'), '2');
      expect(page.title, '📢 公告 & 新手報到');
      expect(page.rulesElement, isNull, reason: 'the forum has no rules');
      expect(page.needLogin, isFalse);
      expect(page.havePermission, isTrue);
      expect(page.permissionDeniedMessage, isNull);
      expect(page.currentPage, 1);
      expect(page.totalPages, 3);
      expect(page.canLoadMore, isTrue);
      expect(page.pollOfferUid, 35, reason: 'allow_poll 1, uid 35');

      // The sticky rows, in the forum's order (global, in type, in forum), apart from the normal ones.
      expect(page.stickThreadList.map((e) => e.threadID), ['9199849', '9199845', '9199841']);
      expect(page.stickThreadList.map((e) => e.stateSet), [
        {ThreadStateModel.pinnedGlobally},
        {ThreadStateModel.pinnedInType},
        {ThreadStateModel.pinnedInSubreddit, ThreadStateModel.digested},
      ]);
      expect(page.normalThreadList, hasLength(19));
      expect(page.normalThreadList.first.threadID, '9199838');
      expect(page.normalThreadList.every((e) => e.stateSet.every((s) => !s.name.startsWith('pinned'))), isTrue);

      // The subforum.
      expect(page.subredditList.map((e) => e.name), ['GLTEST 子版塊（型別 sub）']);

      // No types: no type filter at all, as the page shows no type row.
      expect(page.filterTypeList, isEmpty);
      // The menus of the page, in its order and names, each with the page's "everything" entry first.
      final filters = _json('forum_v2_fid2.json')['filters'] as Map<String, dynamic>;
      List<String> names(String menu) => (filters[menu] as List).map((e) => (e as Map)['name'] as String).toList();
      List<String> values(String menu) => (filters[menu] as List).map((e) => '${(e as Map)['value']}').toList();
      expect(page.filterSpecialTypeList.map((e) => e.name), ['全部主题', ...names('specialtype')]);
      expect(page.filterSpecialTypeList.map((e) => e.specialType), [null, ...values('specialtype')]);
      expect(page.filterSpecialTypeList.length, greaterThan(1), reason: 'the forum allows polls');
      expect(page.filterOrderList.map((e) => e.name), ['默认排序', ...names('orderby')]);
      expect(page.filterOrderList.map((e) => e.orderBy), [null, ...values('orderby')]);
      expect(
        page.filterOrderList.map((e) => e.orderBy),
        containsAll(['lastpost', 'dateline', 'replies', 'views', 'heats']),
      );
      expect(page.filterDatelineList.map((e) => e.name), ['全部时间', ...names('dateline')]);
      expect(page.filterDatelineList.map((e) => e.dateline), [null, ...values('dateline')]);
      expect(page.filterDatelineList.map((e) => e.dateline), contains('86400'));
      for (final filter in [...page.filterSpecialTypeList, ...page.filterOrderList, ...page.filterDatelineList]) {
        expect(filter.filterName, isIn(['specialtype', 'orderby', 'dateline']));
      }
    });

    test('a forum that allows no special thread: the menu is its "everything" entry only', () {
      final json = _json('forum_v2_fid13.json');
      expect((json['filters'] as Map<String, dynamic>)['specialtype'], isEmpty);
      final page = forumPageFromApi(json, '13');
      expect(page.filterSpecialTypeList.map((e) => e.name), ['全部主题']);
      expect(page.filterSpecialTypeList.single.specialType, isNull);
      expect(page.filterOrderList.first.name, '默认排序');
      expect(page.filterOrderList.length, greaterThan(1));
    });

    test('page 2 of 3, and the only page of a forum', () {
      final page2 = forumPageFromApi(_json('forum_v2_fid2_p2.json'), '2');
      expect(page2.currentPage, 2);
      expect(page2.totalPages, 3);
      expect(page2.canLoadMore, isTrue);
      expect(page2.stickThreadList, isEmpty, reason: 'the forum lists the sticky threads on page 1 only');
      expect(page2.normalThreadList, hasLength(20));

      final only = forumPageFromApi(_json('forum_v2_fid13.json'), '13');
      expect(only.currentPage, 1);
      expect(only.totalPages, 1);
      expect(only.canLoadMore, isFalse);
    });

    test('the thread types are the type filter, with "全部" first, only when the forum lists them (listable)', () {
      // fid 13 has three types but does not list them: the page shows no type row, the app no filter bar.
      final json = _json('forum_v2_fid13.json');
      final types = json['types'] as Map<String, dynamic>;
      expect(types['listable'], 0);
      expect(types['items'], hasLength(3));
      expect(forumPageFromApi(json, '13').filterTypeList, isEmpty);

      types['listable'] = 1;
      final page = forumPageFromApi(json, '13');
      expect(page.filterTypeList.map((e) => e.name), ['全部', '年度分享', '版主公告', '其他']);
      expect(page.filterTypeList.map((e) => e.typeID), [null, '3', '4', '5']);
      expect(page.filterTypeList.map((e) => e.filterName).toSet(), {'typeid'});

      // Listed, but no types at all: no filter either.
      final none = _json('forum_v2_fid2.json');
      (none['types'] as Map<String, dynamic>)['listable'] = 1;
      expect(forumPageFromApi(none, '2').filterTypeList, isEmpty);

      // A type filter with nothing in it: the lists stay, nothing listed.
      final filtered = forumPageFromApi(_json('forum_v2_fid13_type3.json'), '13');
      expect(filtered.filterTypeList, isEmpty, reason: 'listable 0 there as well');
      expect(filtered.filterOrderList, isNotEmpty);
      expect(filtered.normalThreadList, isEmpty);
      expect(filtered.stickThreadList, isEmpty);
      expect(filtered.havePermission, isTrue);
      expect(filtered.needLogin, isFalse);
      expect(filtered.canLoadMore, isFalse);
    });

    test('a dateline filter sorted by views: the rows as the forum sorted them', () {
      final page = forumPageFromApi(_json('forum_v2_fid6_dateline.json'), '6');
      expect(page.title, '新番追蹤');
      expect(page.normalThreadList, hasLength(20));
      expect(page.currentPage, 1);
      expect(page.totalPages, 4);
      final views = page.normalThreadList.map((e) => e.viewCount).toList();
      expect(views, [...views]..sort((a, b) => b.compareTo(a)), reason: 'orderby views DESC');
    });

    test('the rules of the forum become the rules element the page has', () {
      final json = _json('forum_v2_fid2.json');
      (json['forum'] as Map<String, dynamic>)['rules'] = '<p>版規 <b>一</b></p><p>二</p>';
      final page = forumPageFromApi(json, '2');
      expect(page.rulesElement?.id, 'forum_rules_2');
      expect(page.rulesElement?.querySelectorAll('p').map((e) => e.innerText), ['版規 一', '二']);
      expect(page.rulesElement?.querySelector('b')?.innerText, '一');
    });

    test('no poll offer for a guest, nor where the forum does not allow polls', () {
      final guest = forumPageFromApi(_json('forum_v2_fid2_guest.json'), '2');
      expect(guest.pollOfferUid, isNull, reason: 'uid 0');
      expect(guest.title, '📢 公告 & 新手報到');
      expect(guest.normalThreadList, isNotEmpty);

      final noPoll = forumPageFromApi(_json('forum_v2_fid12_defstyle.json'), '12');
      expect(noPoll.pollOfferUid, isNull, reason: 'allow_poll 0');
    });

    test('a picture mode board: the same rows whichever view the forum answered', () {
      final wall = forumPageFromApi(_json('forum_v2_fid12.json'), '12');
      final list = forumPageFromApi(_json('forum_v2_fid12_defstyle.json'), '12');
      expect(wall.title, '繪圖・插畫');
      expect(wall.normalThreadList, hasLength(20));
      expect(wall.stickThreadList, isEmpty, reason: 'the wall lists no sticky thread');
      expect(list.stickThreadList.map((e) => e.threadID), ['9199849'], reason: 'the global sticky thread');
      expect(list.normalThreadList, hasLength(20));
      expect(wall.totalPages, list.totalPages);
    });

    test("the forum's message: no permission, the login prompt, a pending application", () {
      final denied = forumPageFromApi(_json('forum_v2_fid26_denied.json'), '26');
      expect(denied.havePermission, isFalse);
      expect(denied.needLogin, isFalse);
      expect(denied.permissionDeniedMessage?.tagName, 'P');
      expect(denied.permissionDeniedMessage?.innerText, '抱歉，您没有权限访问该版块');
      expect(denied.normalThreadList, isEmpty);
      expect(denied.subredditList, isEmpty);
      expect(denied.title, isNull);
      expect(denied.canLoadMore, isFalse);
      expect(denied.currentPage, isNull);
      expect(denied.pollOfferUid, isNull);

      final guest = forumPageFromApi(_json('forum_v2_fid29_guest.json'), '29');
      expect(guest.needLogin, isTrue);
      expect(guest.havePermission, isTrue, reason: 'as the page path: the login prompt is not a denial');
      expect(guest.permissionDeniedMessage, isNull);

      final pending = forumPageFromApi(_json('forum_v2_fid29_pending.json'), '29');
      expect(pending.havePermission, isFalse);
      expect(pending.permissionDeniedMessage?.innerText, '您已提交了本版块的访问申请，请等待审核');
    });

    test('the message is text, never markup', () {
      final page = forumPageFromApi({
        'ok': 0,
        'error': 'message',
        'message': 'a <b>b</b> & "c"',
        'login': 0,
      }, '1');
      expect(page.permissionDeniedMessage?.innerText, 'a <b>b</b> & "c"');
      expect(page.permissionDeniedMessage?.querySelector('b'), isNull);
    });
  });

  group('NormalThread.fromApi', () {
    test('a row: identity, author, times, counts', () {
      final t = _thread('forum_v2_fid2.json', 9199849);
      expect(t.threadID, '9199849');
      expect(t.title, '1.8.0 分类标签验收（原生）711734');
      expect(t.url, '$baseUrl/forum.php?mod=viewthread&tid=9199849');
      expect(t.author.name, 'ag_admin');
      expect(t.author.uid, '32');
      expect(t.author.url, '$baseUrl/home.php?mod=space&uid=32');
      expect(t.author.avatarUrl, avatarUrlOfUid('32'), reason: 'built from the uid as the page path does');
      expect(t.latestReplyAuthor.name, 'ag_admin');
      expect(t.latestReplyAuthor.uid, '32');
      expect(t.latestReplyAuthor.url, '$baseUrl/home.php?mod=space&username=ag_admin');
      expect(t.replyCount, 0);
      // Views are live data (every fetch of the thread adds one): the count of the row.
      final views = _row('forum_v2_fid2.json', 9199849)['views'] as int;
      expect(views, greaterThan(0));
      expect(t.viewCount, views);
      expect(t.price, isNull);
      expect(t.privilege, isNull);
      expect(t.css, isNull);
      expect(t.iconUrl, '');
      expect(t.threadType, isNull);
      expect(t.isRecentThread, isFalse);
      expect(t.stateSet, {ThreadStateModel.pinnedGlobally});
    });

    test("times: the last reply the real instant, the publish date the forum's wall clock", () {
      final t = _thread('forum_v2_fid2.json', 9199345);
      // Shown as a date: the clock the forum (zone +8) prints, whatever the device's zone.
      expect(t.publishDate, tsdmAppWallClockTime(1790763526, 8));
      expect(t.publishDate?.isUtc, isFalse, reason: 'a naive DateTime holding the clock of the page');
      // Shown relative to now: the real instant.
      expect(t.latestReplyTime, DateTime.fromMillisecondsSinceEpoch(1790957056 * 1000));
      // What the forum (zone +8) prints for it, whatever the device's zone.
      expect(_forumClock(t.latestReplyTime), '2026-10-03 00:04:16');
    });

    test('the sticky levels', () {
      expect(_thread('forum_v2_fid2.json', 9199849).stateSet, contains(ThreadStateModel.pinnedGlobally));
      expect(_thread('forum_v2_fid2.json', 9199845).stateSet, contains(ThreadStateModel.pinnedInType));
      expect(_thread('forum_v2_fid2.json', 9199841).stateSet, contains(ThreadStateModel.pinnedInSubreddit));
    });

    test('closed, and a moved thread: the row of its target, closed, as the page links it', () {
      final closed = _thread('forum_v2_fid2.json', 9199835);
      expect(closed.stateSet, {ThreadStateModel.closed});
      expect(closed.threadID, '9199835');
      final moved = _thread('forum_v2_fid2.json', 9199834);
      expect(_row('forum_v2_fid2.json', 9199834)['moved'], 9199849);
      expect(moved.stateSet, contains(ThreadStateModel.closed));
      expect(moved.threadID, '9199849', reason: 'the target, as the page path reads it from the title link');
      expect(moved.url, '$baseUrl/forum.php?mod=viewthread&tid=9199849');
      expect(moved.title, 'OLF 舊網域連結測試', reason: "the pointer row's own subject");
      final open = _thread('forum_v2_fid2.json', 9199849);
      expect(open.stateSet, isNot(contains(ThreadStateModel.closed)));
    });

    test("a thread pushed from a group is the row of the group's thread", () {
      final row = _row('forum_v2_fid2.json', 9199849)..['grouptid'] = 7700;
      final t = NormalThread.fromApi(row, fid: 2, typePrefix: 0);
      expect(t.threadID, '7700');
      expect(t.url, '$baseUrl/forum.php?mod=viewthread&tid=7700');
      expect(t.replyCount, 0, reason: 'replies 0 in the row');
      // Moved wins over the group's thread.
      final both = NormalThread.fromApi(row..['moved'] = 7800, fid: 2, typePrefix: 0);
      expect(both.threadID, '7800');
      // grouptid 0 (every ordinary row) changes nothing.
      expect(_row('forum_v2_fid2.json', 9199849)['grouptid'], 0);
      expect(_thread('forum_v2_fid2.json', 9199849).threadID, '9199849');
    });

    test('a digest with a highlighted title: bold and red', () {
      final t = _thread('forum_v2_fid2.json', 9199838);
      expect(t.stateSet, {ThreadStateModel.digested});
      expect(t.css?.color, const Color(0xFFEE1B2E));
      expect(t.css?.fontWeight, FontWeight.bold);
      expect(t.css?.backgroundColor, isNull);
      // digest 2 is a digest as well.
      expect(_thread('forum_v2_fid2.json', 9199841).stateSet, contains(ThreadStateModel.digested));
    });

    test('an italic-only highlight: a style without the fields the app reads', () {
      final t = _thread('forum_v2_fid2.json', 9199343);
      expect(t.css, isNotNull);
      expect(t.css?.color, isNull);
      expect(t.css?.fontWeight, isNull);
      expect(t.css?.backgroundColor, isNull);
    });

    test('a highlight with a background', () {
      final row = _row('forum_v2_fid2.json', 9199849)
        ..['style'] = {'bold': 0, 'italic': 0, 'underline': 0, 'color': '', 'bgcolor': '#FFFF00'};
      final t = NormalThread.fromApi(row, fid: 2, typePrefix: 0);
      expect(t.css?.backgroundColor, const Color(0xFFFFFF00));
      expect(t.css?.color, isNull);
      expect(t.css?.fontWeight, isNull);
    });

    test('price and read permission, rated up', () {
      final t = _thread('forum_v2_fid2.json', 9199345);
      expect(t.price, 5);
      expect(t.privilege, 10);
      expect(t.stateSet, {ThreadStateModel.upVoted});
    });

    test('attachments: a picture, a file (the same state), rated', () {
      final picture = _thread('forum_v2_fid2.json', 9199344);
      expect(_row('forum_v2_fid2.json', 9199344)['attachment'], 2);
      expect(picture.stateSet, {ThreadStateModel.pictureAttached, ThreadStateModel.upVoted});

      final file = NormalThread.fromApi(_row('forum_v2_fid2.json', 9199344)..['attachment'] = 1, fid: 2, typePrefix: 0);
      expect(file.stateSet, contains(ThreadStateModel.pictureAttached));

      // Rated down is not rated up.
      final down = _thread('forum_v2_fid2.json', 9199193);
      expect(_row('forum_v2_fid2.json', 9199193)['rate'], -1);
      expect(down.stateSet, isNot(contains(ThreadStateModel.upVoted)));
    });

    test('a poll, a reward (its reward is not a price)', () {
      final poll = _thread('forum_v2_fid2.json', 9199099);
      expect(poll.stateSet, {ThreadStateModel.poll, ThreadStateModel.upVoted});

      final reward = NormalThread.fromApi(
        _row('forum_v2_fid2.json', 9199849)
          ..['special'] = 3
          ..['price'] = 20
          ..['displayorder'] = 0,
        fid: 2,
        typePrefix: 0,
      );
      expect(reward.stateSet, {ThreadStateModel.rewarded});
      expect(reward.price, isNull);
    });

    test('the reply count is replies plus comments, as the page prints it', () {
      expect(_row('forum_v2_fid25.json', 9199033)['comments'], 1);
      expect(_thread('forum_v2_fid25.json', 9199033).replyCount, 5 + 1);
      expect(_row('forum_v2_fid25.json', 9199072)['comments'], 2);
      expect(_thread('forum_v2_fid25.json', 9199072).replyCount, 18 + 2);
      // No comments: the replies alone.
      expect(_row('forum_v2_fid2.json', 9199345)['comments'], 0);
      expect(_thread('forum_v2_fid2.json', 9199345).replyCount, 8);
      // A moved thread: the page prints `-` for the pointer row, 0 here whatever the row carries.
      final moved = NormalThread.fromApi(
        _row('forum_v2_fid2.json', 9199834)
          ..['replies'] = 4
          ..['comments'] = 3,
        fid: 2,
        typePrefix: 0,
      );
      expect(moved.replyCount, 0);
    });

    test('published today', () {
      // `istoday` is the day of the fetch (a fixture fetched the next day has none): the flag of the row, either way.
      NormalThread withToday(int tid, int today) =>
          NormalThread.fromApi(_row('forum_v2_fid12.json', tid)..['istoday'] = today, fid: 12, typePrefix: 0);
      expect(withToday(9199945, 1).isRecentThread, isTrue);
      expect(withToday(9199945, 0).isRecentThread, isFalse);
      expect(_row('forum_v2_fid12.json', 9199868)['istoday'], 0);
      expect(_thread('forum_v2_fid12.json', 9199868).isRecentThread, isFalse);
    });

    test('the thread type only when the forum shows types as a prefix, as the page prints the tag then', () {
      // fid 13: types.prefix 0, the thread has a type: the page prints no tag.
      final json = _json('forum_v2_fid13.json');
      expect((json['types'] as Map<String, dynamic>)['prefix'], 0);
      expect(_row('forum_v2_fid13.json', 9199449)['typeid'], 4);
      expect(_thread('forum_v2_fid13.json', 9199449).threadType, isNull);
      expect(
        forumPageFromApi(json, '13').normalThreadList.firstWhere((e) => e.threadID == '9199449').threadType,
        isNull,
      );

      final tagged = _thread('forum_v2_fid13.json', 9199449, typePrefix: 1).threadType;
      expect(tagged?.name, '版主公告');
      expect(tagged?.url, '$baseUrl/forum.php?mod=forumdisplay&fid=13&filter=typeid&typeid=4');
      expect(_thread('forum_v2_fid13.json', 9199449, typePrefix: 2).threadType?.name, '版主公告');

      // A thread without a type has none whatever the prefix.
      expect(_thread('forum_v2_fid2.json', 9199849, typePrefix: 1).threadType, isNull);
    });

    test('an anonymous author and last replier', () {
      final row = _row('forum_v2_fid25.json', 9199069);
      expect(row['anonymous'], 1);
      expect(row['authorid'], 0);
      final t = _thread('forum_v2_fid25.json', 9199069);
      expect(t.author.name, '匿名');
      expect(t.author.uid, isNull);
      expect(t.author.url, '');
      expect(t.author.avatarUrl, isNull);
      expect(t.latestReplyAuthor.name, '匿名');
      expect(t.latestReplyAuthor.uid, isNull);
      expect(t.latestReplyAuthor.url, '');

      // `anonymous` is the flag: a row flagged so is anonymous whatever else it carries.
      final flagged = NormalThread.fromApi(
        _row('forum_v2_fid2.json', 9199849)..['anonymous'] = 1,
        fid: 2,
        typePrefix: 0,
      );
      expect(flagged.author.name, '匿名');
      expect(flagged.author.uid, isNull);
      expect(flagged.author.url, '');
      expect(flagged.author.avatarUrl, isNull);

      // The forum gives no id for a last replier it cannot look up: a name without a uid.
      final unknown = NormalThread.fromApi(
        _row('forum_v2_fid2.json', 9199849)..['lastposterid'] = 0,
        fid: 2,
        typePrefix: 0,
      );
      expect(unknown.latestReplyAuthor.name, 'ag_admin');
      expect(unknown.latestReplyAuthor.uid, isNull);
      expect(unknown.latestReplyAuthor.url, '$baseUrl/home.php?mod=space&username=ag_admin');

      // An author the forum names but gives no id for (anonymous by the spec): named, without a link by uid.
      final named = NormalThread.fromApi(_row('forum_v2_fid2.json', 9199849)..['authorid'] = 0, fid: 2, typePrefix: 0);
      expect(named.author.name, 'ag_admin');
      expect(named.author.uid, isNull);
      expect(named.author.url, '$baseUrl/home.php?mod=space&username=ag_admin');
      expect(named.author.avatarUrl, isNull);
    });

    test('a username is encoded in the url', () {
      final row = _row('forum_v2_fid2.json', 9199849)..['lastposter'] = '神代 小祈&';
      final t = NormalThread.fromApi(row, fid: 2, typePrefix: 0);
      expect(t.latestReplyAuthor.url, '$baseUrl/home.php?mod=space&username=${Uri.encodeComponent('神代 小祈&')}');
    });

    test('a sort (threadsorts) is not a type', () {
      final t = _thread('forum_v2_fid25.json', 9199068);
      expect(_row('forum_v2_fid25.json', 9199068)['sortid'], 1);
      expect(t.threadType, isNull);
    });

    test('StickThread.fromApi is the same row as a sticky one', () {
      final row = _row('forum_v2_fid2.json', 9199849);
      final sticky = StickThread.fromApi(row, fid: 2, typePrefix: 0);
      final normal = NormalThread.fromApi(row, fid: 2, typePrefix: 0);
      expect(sticky, isA<StickThread>());
      expect(sticky.threadID, normal.threadID);
      expect(sticky.title, normal.title);
      expect(sticky.author, normal.author);
      expect(sticky.publishDate, normal.publishDate);
      expect(sticky.latestReplyTime, normal.latestReplyTime);
      expect(sticky.stateSet, normal.stateSet);
    });
  });

  group('Forum.fromApi', () {
    test('a subforum with a last post', () {
      final page = forumPageFromApi(_json('forum_v2_fid2.json'), '2');
      final forum = page.subredditList.single;
      expect(forum.forumID, 15);
      expect(forum.name, 'GLTEST 子版塊（型別 sub）');
      expect(forum.url, '$baseUrl/forum.php?mod=forumdisplay&fid=15');
      expect(forum.iconUrl, '');
      expect(forum.threadCount, 10);
      expect(forum.replyCount, 10);
      expect(forum.threadTodayCount, isNull, reason: 'todayposts 0: the page prints no count');
      expect(forum.latestThreadUrl, '$baseUrl/forum.php?mod=redirect&tid=9199857&goto=lastpost');
      expect(forum.latestThreadTitle, '1.9.0 子版发帖 758113');
      expect(forum.latestThreadTime, DateTime.fromMillisecondsSinceEpoch(1792256772 * 1000));
      expect(_forumClock(forum.latestThreadTime), '2026-10-18 01:06:12');
      expect(forum.latestThreadTimeText, forum.latestThreadTime?.yyyyMMDDHHMM());
      expect(forum.latestThreadUserName, 'ag_low2');
      expect(forum.latestThreadUserUrl, '$baseUrl/home.php?mod=space&username=ag_low2');
      expect(forum.subForumList, isNull, reason: 'no subforums of its own: the page has no such row');
      expect(forum.subThreadList, isNull);
      expect(forum.isExpanded, isTrue, reason: 'the card shows the last post');
    });

    test('a redirect forum without a thread, with posts today and subforums of its own', () {
      final forum = Forum.fromApi({
        'fid': 40,
        'name': '外連',
        'description': '',
        'icon': 'https://example.invalid/forum/x.png',
        'namecolor': '',
        'threads': 0,
        'posts': 0,
        'todayposts': 3,
        'redirect': 'https://example.invalid/',
        'lastpost': null,
        'moderators': <String>[],
        'subforums': [
          {'fid': 41, 'name': '甲'},
          {'fid': 42, 'name': '乙'},
        ],
        'permission': 2,
      });
      expect(forum.url, 'https://example.invalid/');
      expect(forum.iconUrl, 'https://example.invalid/forum/x.png');
      expect(forum.threadTodayCount, 3);
      expect(forum.latestThreadUrl, isNull);
      expect(forum.latestThreadTitle, isNull);
      expect(forum.latestThreadTime, isNull);
      expect(forum.latestThreadTimeText, isNull);
      expect(forum.latestThreadUserName, isNull);
      expect(forum.latestThreadUserUrl, isNull);
      expect(forum.isExpanded, isFalse);
      expect(forum.subForumList, [
        ('甲', '$baseUrl/forum.php?mod=forumdisplay&fid=41'),
        ('乙', '$baseUrl/forum.php?mod=forumdisplay&fid=42'),
      ]);
    });
  });

  group('ForumRepository.fetchForum', () {
    test('schema 2: the page is built from the fields, the document is never parsed', () async {
      final raw = _raw('forum_v2_fid2.json');
      expect(raw, contains(r'"document":"<div id=\"wp\">nothing</div>"'), reason: 'the garbage document is there');
      final page = (await _fetch(raw)).getOrElse((e) => throw e);
      expect(page.title, '📢 公告 & 新手報到');
      expect(page.stickThreadList, hasLength(3));
      expect(page.normalThreadList, hasLength(19));
      expect(page.subredditList, hasLength(1));
      expect(page.havePermission, isTrue);
      expect(page.needLogin, isFalse);
      expect(page.pollOfferUid, 35);
    });

    test('schema 2 without a document is a page, not an answer without one', () async {
      expect(_raw('forum_v2_fid13.json'), isNot(contains('"document"')));
      final page = (await _fetch(_raw('forum_v2_fid13.json'), fid: '13')).getOrElse((e) => throw e);
      expect(page.title, 'COS・攝影');
      expect(page.stickThreadList.map((e) => e.threadID), ['9199849'], reason: 'the global sticky thread');
      expect(page.normalThreadList, hasLength(2));
      expect(page.filterTypeList, isEmpty, reason: 'the forum does not list its types');
    });

    test('the message of plugin 2.0.0, without a document', () async {
      final denied = (await _fetch(_raw('forum_v2_fid26_denied.json'), fid: '26')).getOrElse((e) => throw e);
      expect(denied.havePermission, isFalse);
      expect(denied.needLogin, isFalse);
      expect(denied.permissionDeniedMessage?.innerText, '抱歉，您没有权限访问该版块');

      final guest = (await _fetch(_raw('forum_v2_fid29_guest.json'), fid: '29')).getOrElse((e) => throw e);
      expect(guest.needLogin, isTrue);
    });

    test('an older plugin (no schema) is parsed from its document as before', () async {
      final raw = _raw('forum_fid2.json');
      expect(raw, isNot(contains('"schema"')));
      final page = (await _fetch(raw)).getOrElse((e) => throw e);
      final web = parseForumPage(tsdmAppPageDocument(raw), '2');
      expect(page.title, web.title);
      expect(page.title, '📢 公告 & 新手報到');
      expect(page.currentPage, web.currentPage);
      expect(page.totalPages, web.totalPages);
      expect(page.canLoadMore, web.canLoadMore);
      expect(page.normalThreadList.map((e) => e.threadID), web.normalThreadList.map((e) => e.threadID));
      expect(page.subredditList.map((e) => e.forumID), web.subredditList.map((e) => e.forumID));
      expect(page.filterSpecialTypeList.map((e) => e.name), web.filterSpecialTypeList.map((e) => e.name));

      final deniedRaw = _raw('forum_denied.json');
      expect(deniedRaw, isNot(contains('"login"')));
      final denied = (await _fetch(deniedRaw, fid: '26')).getOrElse((e) => throw e);
      final deniedWeb = parseForumPage(tsdmAppPageDocument(deniedRaw), '26');
      expect(denied.havePermission, isFalse);
      expect(denied.permissionDeniedMessage?.innerText.trim(), deniedWeb.permissionDeniedMessage?.innerText.trim());
    });

    test('an older plugin (1.9.0): the production markup in its document is parsed as the web page', () async {
      // The test forum's template lists threads as `<li>` (parsed by neither path), so the production rows are the
      // fixtures of the page parsers, wrapped into a 1.9.0 answer (no `schema`, no `login`).
      final rows = File('test/data/forum_thread_list_authors_x5.html').readAsStringSync();
      final page = (await _fetch(jsonEncode({'ok': 1, 'api': 1, 'type': 'forum', 'document': rows}))).getOrElse(
        (e) => throw e,
      );
      final web = parseForumPage(parseHtmlDocument(rows), '2');
      expect(web.normalThreadList.map((e) => e.threadID), ['1000001', '1000002', '1000003']);
      expect(page.normalThreadList.map((e) => e.threadID), web.normalThreadList.map((e) => e.threadID));
      expect(page.normalThreadList.map((e) => e.author.uid), web.normalThreadList.map((e) => e.author.uid));
      expect(page.normalThreadList.map((e) => e.author.name), web.normalThreadList.map((e) => e.author.name));
      expect(page.normalThreadList.map((e) => e.stateSet), web.normalThreadList.map((e) => e.stateSet));
      expect(
        page.normalThreadList.map((e) => e.latestReplyAuthor.name),
        web.normalThreadList.map((e) => e.latestReplyAuthor.name),
      );
      // The third row's author cell is `<cite>匿名</cite>` without a link: the page path falls back to the last reply
      // cell (regression 078), the same on both sides, and nothing like the structured path's "匿名" row.
      expect(page.normalThreadList[2].author.uid, isNull);
      expect(page.normalThreadList[2].author.name, web.normalThreadList[2].author.name);
      expect(page.normalThreadList.map((e) => e.author.name), isNot(contains('匿名')));

      final filters = File('test/data/forum_thread_filters_x5.html').readAsStringSync();
      final filterPage = (await _fetch(
        jsonEncode({'ok': 1, 'api': 1, 'type': 'forum', 'document': filters}),
        fid: '4',
      )).getOrElse((e) => throw e);
      final filterWeb = parseForumPage(parseHtmlDocument(filters), '4');
      expect(filterWeb.filterTypeList.length, greaterThan(1));
      expect(filterPage.filterTypeList.map((e) => e.name), filterWeb.filterTypeList.map((e) => e.name));
      expect(filterPage.filterTypeList.map((e) => e.typeID), filterWeb.filterTypeList.map((e) => e.typeID));
      expect(filterPage.filterSpecialTypeList.map((e) => e.name), filterWeb.filterSpecialTypeList.map((e) => e.name));
      expect(filterPage.filterOrderList.map((e) => e.orderBy), filterWeb.filterOrderList.map((e) => e.orderBy));
      expect(filterPage.filterDatelineList.map((e) => e.name), filterWeb.filterDatelineList.map((e) => e.name));
      expect(filterPage.normalThreadList.map((e) => e.threadID), filterWeb.normalThreadList.map((e) => e.threadID));
    });

    test('a web page (a forum without the plugin) is parsed as before', () async {
      const html =
          '<html><body><div id="wp"><div id="ct"><h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=2">板</a></h1> '
          '</div><div id="messagetext" class="alert_info"><p>抱歉，您没有权限访问该版块</p></div> '
          '<div id="pgt"></div></div></body></html>';
      final page = (await _fetch(html, contentType: 'text/html; charset=utf-8')).getOrElse((e) => throw e);
      expect(page.title, '板');
      expect(page.havePermission, isFalse);
      expect(page.permissionDeniedMessage?.innerText, '抱歉，您没有权限访问该版块');
    });

    test('an answer without a page is still a failed request', () async {
      for (final body in ['{"ok":0,"error":"internal"}', '{"ok":0,"error":"unknown"}', '']) {
        final result = await _fetch(body);
        expect(result.getLeft().toNullable(), isA<HttpRequestFailedException>(), reason: body);
      }
    });
  });

  test('the fixtures carry nothing of the test forum but the pages', () {
    final files = Directory(_dir).listSync().whereType<File>().where((f) => f.path.contains('forum_v2_')).toList();
    expect(files.length, 12);
    for (final file in files) {
      final raw = file.readAsStringSync();
      // No host of the forum (the plugin gives relative paths), no address, no page head, no member data.
      expect(raw, isNot(contains('http://')), reason: file.path);
      expect(raw, isNot(contains('https://')), reason: file.path);
      expect(raw, isNot(matches(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'))), reason: '${file.path}: an IPv4 address');
      for (final marker in ['"head"', '"password"', '"email"', '"loginname"']) {
        expect(raw, isNot(contains(marker)), reason: '${file.path} $marker');
      }
      if (!file.path.endsWith('forum_v2_fid2.json')) {
        expect(raw, isNot(contains('"document"')), reason: file.path);
      }
    }
  });

  group('the thread card of an anonymous author', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late Directory tmp;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_forum_api_');
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
          'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
          'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
          'getApplicationDocumentsPath' || 'getApplicationDocumentsDirectory' => '${tmp.path}/docs',
          _ => null,
        },
      );
      await initCache();
    });

    tearDownAll(() => tmp.delete(recursive: true));

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(
            NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Forum('', contentType: 'text/html')),
          ),
        );
      await settings.init();
    });

    tearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.unregister<ImageCacheProvider>();
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await settings.dispose();
      await db.close();
    });

    /// The card of [thread] in an app whose router knows the "open in app" page, pumped until the card is built.
    Future<GoRouter> pump(WidgetTester tester, NormalThread thread) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(body: ListView(children: [NormalThreadCard(thread)])),
          ),
          GoRoute(
            path: ScreenPaths.openInApp,
            name: ScreenPaths.openInApp,
            builder: (_, _) => const Scaffold(body: Text('OPEN IN APP')),
          ),
          // The card itself opens the thread: a tap on the author that opens nothing falls through to it.
          GoRoute(
            path: ScreenPaths.threadV1,
            name: ScreenPaths.threadV1,
            builder: (_, _) => const Scaffold(body: Text('THREAD')),
          ),
        ],
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          TranslationProvider(
            child: BlocProvider<SettingsBloc>(
              create: (_) => SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository()),
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        );
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
          if (i > 4 && find.byType(HeroUserAvatar).evaluate().isNotEmpty) {
            return;
          }
        }
      });
      return router;
    }

    GestureDetector detectorOf(WidgetTester tester, Finder child) =>
        tester.widget<GestureDetector>(find.ancestor(of: child, matching: find.byType(GestureDetector)).first);

    testWidgets('tapping the name or the avatar opens nothing', (tester) async {
      // The anonymous row, with a named last replier so that "匿名" is the author's name only.
      final thread = NormalThread.fromApi(
        _row('forum_v2_fid25.json', 9199069)
          ..['lastposter'] = 'ag_low2'
          ..['lastposterid'] = 35,
        fid: 25,
        typePrefix: 0,
      );
      expect(thread.author.name, '匿名');
      expect(thread.author.url, '');
      final router = await pump(tester, thread);

      expect(find.text('匿名'), findsOneWidget);
      expect(detectorOf(tester, find.text('匿名')).onTap, isNull);
      expect(detectorOf(tester, find.byType(HeroUserAvatar)).onTap, isNull);

      // A tap on the name falls through to the card, which opens the thread, never the "open in app" page.
      await tester.tap(find.text('匿名'));
      await tester.pumpAndSettle();
      expect(find.text('OPEN IN APP'), findsNothing);
      expect(router.state.uri.path, ScreenPaths.threadV1);
    });

    testWidgets('a named author keeps the tap', (tester) async {
      final thread = _thread('forum_v2_fid2.json', 9199849);
      expect(thread.author.url, isNotEmpty);
      await pump(tester, thread);
      expect(detectorOf(tester, find.text('ag_admin')).onTap, isNotNull);
    });
  });
}
