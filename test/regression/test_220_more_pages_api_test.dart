/// The forum's app API, plugin 2.5.0: the favorites (`schema: 8`), the friends lists (`schema: 10`), a private
/// message conversation (`schema: 11`) and the credit log (`schema: 12`) answered as structured fields, each with a
/// shape of its own.
///
/// The pages are asked in the JSON mode as before, but an answer of plugin 2.5.0 carries every field the app reads:
/// the favorite records (the record id, the thread or forum, the note, the exact time), the friends (the member,
/// the avatar, the user group, the credits on another member's list), the messages of a conversation (the author,
/// the avatar, the exact time, the html the renderer takes) with the reply form, the credit changes (the operation,
/// the signed changes, the detail and its link, the exact time) with the filters of the query form, and the
/// pagination (`page`, `pages`, `has_next`; the conversation serves its LAST page when none is asked). The readers
/// build the models the pages show ([favoriteThreadsFromApi], [friendListPageFromApi], [chatHistoryFromApi],
/// [pointsChangelogFromApi]) and never parse the `document` of such an answer; the repositories hand the answer over
/// as a [TsdmAppStructuredPage] (or build the page themselves), and the web page (or an older plugin's answer) as a
/// [TsdmAppWebPage] parsed as before.
///
/// The fixtures `favorite_v8_*.json`, `friend_v10_*.json`, `pm_v11_*.json` and `credit_v12_*.json` are answers of
/// the test forum (Discuz X5.0.2 with plugin 2.5.0, 2026-10-21) with their `document` and `head` removed, scrubbed as
/// the earlier groups; `favorite_v8_thread.json`, `friend_v10_me.json`, `pm_v11_view.json` and `credit_v12_log.json`
/// keep a `document` on purpose, a garbage one, to prove that path never reads it. The `*_x5.html` pages of the
/// earlier tests are the old answers, parsed from their document as they always were.
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
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/chat/bloc/chat_history_bloc.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/chat/utils/chat_page_api.dart';
import 'package:tsdm_client/features/chat/utils/parse_chat.dart';
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/favorite/bloc/favorite_bloc.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/utils/favorite_page_api.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/features/friend/bloc/friend_bloc.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/friend_page_api.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/features/points/bloc/points_bloc.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/points/utils/parse_points.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// The rows of [key] of the answer [name].
List<Map<String, dynamic>> _rows(String name, String key) => (_json(name)[key] as List).cast<Map<String, dynamic>>();

/// The answer [name] with [changes] applied on top (a copy).
Map<String, dynamic> _with(String name, Map<String, Object?> changes) => {..._json(name), ...changes};

/// The forum's unix seconds as the instant the app keeps.
DateTime _at(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

String _page(String name) => File('test/data/$name').readAsStringSync();

/// The body of a web page, as the plugin cut it into `document` before 2.0.0.
String _bodyOf(String html) => RegExp('<body>(.*)</body>', dotAll: true).firstMatch(html)?.group(1) ?? html;

/// The credit log page of the forum (template `spacecp_credit_log`), page [page] of 3, two rows: the web page the
/// old path parses, and the blocks plugin 1.7.0 cut from it.
String _creditLogPage({int page = 1}) =>
    '''
<!DOCTYPE html>
<html><head><meta charset="utf-8" /><title>积分 - Synthetic - Powered by Discuz!</title>
<script type="text/javascript">var discuz_uid = '35';</script></head><body>
<div id="wp" class="wp">
<div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm" title="首页">Synthetic</a></div></div>
<div id="ct" class="ct2_a wp cl"><div class="mn"><div class="bm bw0">
<h1 class="mt">积分</h1>
<form method="post" action="home.php?mod=spacecp&amp;ac=credit&amp;op=log">
<select id="exttype" name="exttype"><option value="0">不限</option><option value="2">天使币</option></select>
<select id="income" name="income"><option value="0">不限</option><option value="-1">支出</option><option value="1">收入</option></select>
<select id="optype" name="optype"><option value="">请选择操作类型</option><option value="RPC">评分</option></select>
<table summary="积分收支" cellspacing="0" cellpadding="0" class="dt">
<tr><th width="80">操作</th><th width="80">积分变更</th><th width="80">变更后积分</th><th>详情</th><th width="110">变更时间</th></tr>
<tr><td><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log&amp;optype=RPC">评分</a></td>
<td>天使币 <span class="xi1">+$page</span></td><td>天使币 100</td><td>Synthetic row</td><td>2026-10-14 08:00</td></tr>
<tr><td><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log&amp;optype=RUL">积分规则</a></td>
<td>天使币 <span class="xg1">-2</span></td><td>天使币 98</td><td><a href="forum.php?mod=viewthread&amp;tid=1">A thread</a></td>
<td>2026-10-12 09:15</td></tr>
</table>
</form>
<div class="pgs mtm mbm cl"><div class="pg"><strong>$page</strong><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log&amp;page=2">2</a>
<a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log&amp;page=3">3</a><label><input type="text" name="custompage" class="px" size="2" value="$page" />
<span title="共 3 页"> / 3 页</span></label><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log&amp;page=2" class="nxt">下一页</a></div></div>
</div></div></div>
</div>
<div id="ft" class="wp cl">Footer</div>
</body></html>''';

/// One answer of the fake forum.
typedef _Answer = ({String body, bool json, int status});

_Answer _html(String body) => (body: body, json: false, status: 200);

_Answer _api(Object answer, {int status = 200}) =>
    (body: answer is String ? answer : jsonEncode(answer), json: true, status: status);

/// An older plugin's answer of page [type]: the blocks of the web page [html], no schema.
_Answer _oldApi(String html, String type) =>
    _api({'ok': 1, 'api': 1, 'uid': 35, 'type': type, 'page': 1, 'document': _bodyOf(html)});

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

/// The account the favorites page lists for (the fixtures' account).
final class _Auth extends Fake implements AuthenticationRepository {
  @override
  UserLoginInfo? get currentUser => const UserLoginInfo(username: 'ag_low2', uid: 35);
}

/// A favorite record as the tests compare it.
String _fav(FavoriteItem e) => '${e.type.name}|${e.favid}|${e.targetId}|${e.title}|${e.url}|${e.time}|${e.description}';

/// A credit change as the tests compare it.
String _change(PointsChange c) =>
    '${c.operation}|${c.operationFilterUrl}|${c.pointsChangeType.name}|${c.changeMapString}|${c.detail}|'
    '${c.redirectUrl}|${c.time}';

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
      for (final name in ['thread', 'thread_p2', 'forum', 'empty']) {
        expect(favoriteApiAnswerOf(_raw('favorite_v8_$name.json')), isNotNull, reason: name);
        expect(favoriteApiAnswerOf(_json('favorite_v8_$name.json')), isNotNull, reason: '$name as a map');
      }
      for (final name in ['me', 'me_p2', 'other', 'empty']) {
        expect(friendApiAnswerOf(_raw('friend_v10_$name.json')), isNotNull, reason: name);
        expect(friendApiAnswerOf(_json('friend_v10_$name.json')), isNotNull, reason: '$name as a map');
      }
      for (final name in ['view', 'view_p2', 'view_chat', 'empty']) {
        expect(chatApiAnswerOf(_raw('pm_v11_$name.json')), isNotNull, reason: name);
        expect(chatApiAnswerOf(_json('pm_v11_$name.json')), isNotNull, reason: '$name as a map');
      }
      for (final name in ['log', 'log_p2', 'log_filter']) {
        expect(creditApiAnswerOf(_raw('credit_v12_$name.json')), isNotNull, reason: name);
        expect(creditApiAnswerOf(_json('credit_v12_$name.json')), isNotNull, reason: '$name as a map');
      }
      for (final name in ['favorite_v8_thread_p2', 'friend_v10_me_p2', 'pm_v11_view_p2', 'credit_v12_log_p2']) {
        expect(_json('$name.json'), isNot(contains('document')), reason: '$name is lean');
      }

      // The forum's messages: the guests, and the feature switched off (a message with the schema, no prompt).
      expect(favoriteApiAnswerOf(_raw('favorite_v8_guest.json')), isNotNull);
      expect(friendApiAnswerOf(_raw('friend_v10_guest.json')), isNotNull);
      expect(chatApiAnswerOf(_raw('pm_v11_guest.json')), isNotNull);
      expect(creditApiAnswerOf(_raw('credit_v12_guest.json')), isNotNull);
      expect(favoriteApiAnswerOf({'ok': 0, 'error': 'message', 'message': '收藏功能已关闭', 'schema': 8}), isNotNull);
      expect(friendApiAnswerOf({'ok': 0, 'error': 'message', 'message': '好友功能已关闭', 'schema': 10}), isNotNull);
      expect(chatApiAnswerOf({'ok': 0, 'error': 'message', 'message': '短消息功能已关闭', 'schema': 11}), isNotNull);
      expect(creditApiAnswerOf({'ok': 0, 'error': 'message', 'message': 'x', 'schema': 12}), isNotNull);
      // A 2.2.x plugin's lean message (login tells the guest apart, no schema) is read from its fields as well.
      final older = {'ok': 0, 'error': 'message', 'message': '抱歉，您没有权限访问该内容', 'login': 0, 'uid': 35};
      for (final of in [favoriteApiAnswerOf, friendApiAnswerOf, chatApiAnswerOf, creditApiAnswerOf]) {
        expect(of(older), older);
      }
    });

    test('not: another page, a lower schema, an older plugin, the web page, a failed build, the pages kept on the '
        'document', () {
      expect(favoriteApiAnswerOf(_raw('friend_v10_me.json')), isNull);
      expect(friendApiAnswerOf(_raw('favorite_v8_thread.json')), isNull);
      expect(chatApiAnswerOf(_raw('credit_v12_log.json')), isNull);
      expect(creditApiAnswerOf(_raw('pm_v11_view.json')), isNull);
      expect(favoriteApiAnswerOf(_raw('mythread_v9_thread.json')), isNull, reason: 'the "my threads" page is 9');
      expect(favoriteApiAnswerOf(_with('favorite_v8_thread.json', {'schema': 7})), isNull);
      expect(friendApiAnswerOf(_with('friend_v10_me.json', {'schema': 9})), isNull);
      expect(chatApiAnswerOf(_with('pm_v11_view.json', {'schema': 10})), isNull);
      expect(creditApiAnswerOf(_with('credit_v12_log.json', {'schema': 11})), isNull);

      // The older plugins answered these pages as their type and blocks, no schema: the document as before.
      final favorites = _page('favorite_list_x5.html');
      expect(favoriteApiAnswerOf(favorites), isNull);
      expect(favoriteApiAnswerOf(_oldApi(favorites, 'favorite').body), isNull);
      final friends = _page('friend_list_x5.html');
      expect(friendApiAnswerOf(friends), isNull);
      expect(friendApiAnswerOf(_oldApi(friends, 'friend').body), isNull);
      final history = _page('chat_history_bare_url_x5.html');
      expect(chatApiAnswerOf(history), isNull);
      expect(chatApiAnswerOf(_oldApi(history, 'pm').body), isNull);
      expect(creditApiAnswerOf(_creditLogPage()), isNull);
      expect(creditApiAnswerOf(_oldApi(_creditLogPage(), 'credit').body), isNull);
      // The pages plugin 2.5.0 keeps answering without a schema: the privacy page of another member's friends, the
      // private message list, the credit statistics (`op=base`).
      expect(friendApiAnswerOf(_oldApi(_page('friend_list_privacy_x5.html'), 'friend').body), isNull);
      expect(chatApiAnswerOf(_oldApi(_page('pm_list_bare_url_x5.html'), 'pm').body), isNull);
      expect(
        creditApiAnswerOf({'ok': 1, 'api': 1, 'type': 'credit', 'page': 1, 'document': '<ul class="creditl">'}),
        isNull,
      );

      for (final of in [favoriteApiAnswerOf, friendApiAnswerOf, chatApiAnswerOf, creditApiAnswerOf]) {
        expect(of({'ok': 0, 'error': 'internal'}), isNull);
        expect(of({'ok': 0, 'error': 'message', 'message': 'x', 'document': '<p>x</p>'}), isNull);
        expect(of(null), isNull);
        expect(of(''), isNull);
      }
    });
  });

  group('the favorites: favoriteThreadsFromApi, favoriteForumsFromApi', () {
    final url = FavoriteRepository.listUrlOf(FavoriteType.thread);

    test('every field of the first page of threads, the next page; the garbage document is never read', () {
      expect(_raw('favorite_v8_thread.json'), contains(r'"document":"<div id=\"wp\">nothing</div>"'));
      final page = favoriteThreadsFromApi(_json('favorite_v8_thread.json'), url);
      expect(page.items, hasLength(20));
      expect(page.nextPageUrl, '$url&page=2');
      expect(page.needLogin, isFalse);

      final first = page.items.first;
      expect(first.favid, '271');
      expect(first.tid, '9199099');
      expect(first.targetId, '9199099');
      expect(first.type, FavoriteType.thread);
      expect(first.title, 'PP驗收偽造帖 1790071175911');
      expect(first.url, '$baseUrl/forum.php?mod=viewthread&tid=9199099');
      expect(first.time, _at(1790072000), reason: 'the exact time, which the page only shows to the minute');
      expect(first.description, '最後一則\n三行\n描述', reason: 'the note, its line breaks kept');

      final second = page.items[1];
      expect(second.favid, '270');
      expect(second.tid, '9199104');
      expect(second.description, isNull, reason: 'no note');
      expect(page.items.map((e) => e.favid).take(4), ['271', '270', '269', '268'], reason: 'newest first');
      expect(page.items.last.favid, '252');
    });

    test('page 2 is the last page; the forums; the empty list is a page (count 0), not a message', () {
      final p2 = favoriteThreadsFromApi(_json('favorite_v8_thread_p2.json'), '$url&page=2');
      expect(p2.items, hasLength(1));
      expect(p2.items.single.favid, '251');
      expect(p2.items.single.tid, '9199849');
      expect(p2.items.single.description, '2.5.0 驗收描述：第一行\n第二行 <b>不是標籤</b> & 符號', reason: 'plain text');
      expect(p2.nextPageUrl, isNull);

      final forumUrl = FavoriteRepository.listUrlOf(FavoriteType.forum);
      final forums = favoriteForumsFromApi(_json('favorite_v8_forum.json'), forumUrl);
      expect(forums.items, hasLength(2));
      final first = forums.items.first;
      expect(first.favid, '273');
      expect(first.fid, '13');
      expect(first.targetId, '13');
      expect(first.type, FavoriteType.forum);
      expect(first.title, 'COS・攝影');
      expect(first.url, '$baseUrl/forum.php?mod=forumdisplay&fid=13');
      expect(first.time, _at(1790183600));
      expect(first.description, isNull);
      expect(forums.items.last.fid, '2');
      expect(forums.nextPageUrl, isNull);

      final empty = favoriteThreadsFromApi(_json('favorite_v8_empty.json'), url);
      expect(empty.items, isEmpty);
      expect(empty.nextPageUrl, isNull);
      expect(empty.needLogin, isFalse);

      // The list of a type takes the rows of that type only, as the page parser takes the rows linking it.
      expect(favoriteForumsFromApi(_json('favorite_v8_thread.json'), url).items, isEmpty);
      expect(favoriteThreadsFromApi(_json('favorite_v8_forum.json'), forumUrl).items, isEmpty);
      final ofType = favoriteListPageOfTypeFromApi(_json('favorite_v8_forum.json'), FavoriteType.forum, forumUrl);
      expect(ofType.items, everyElement(isA<FavoriteForum>()));
      expect(ofType.items.map(_fav), forums.items.map(_fav));
      expect(
        favoriteListPageOfTypeFromApi(_json('favorite_v8_thread.json'), FavoriteType.thread, url).items,
        everyElement(isA<FavoriteThread>()),
      );
    });

    test("a row of another kind, without a record or a target is dropped; the url is the forum's, else built", () {
      final row = _rows('favorite_v8_thread.json', 'items').first;
      final rows = [
        {...row, 'favid': 0},
        {...row, 'id': 0},
        {...row, 'kind': 'blog', 'idtype': 'blogid'},
        {...row, 'favid': 1, 'kind': '', 'idtype': 'tid'},
        {...row, 'favid': 2, 'url': ''},
        'not a row',
      ];
      final page = favoriteThreadsFromApi(_with('favorite_v8_thread.json', {'items': rows}), url);
      expect(page.items.map((e) => e.favid), ['1', '2']);
      expect(page.items.last.url, '$baseUrl/forum.php?mod=viewthread&tid=9199099', reason: 'built from the tid');
      expect(FavoriteThread.fromApi({...row, 'dateline': 0})!.time, isNull);
      expect(FavoriteThread.fromApi({...row, 'description': ' '})!.description, isNull);
      expect(page.nextPageUrl, '$url&page=2', reason: "the paging is the forum's");
    });

    test('the guest message asks to log in; the favorites switched off is a message without the prompt', () {
      final guest = favoriteThreadsFromApi(_json('favorite_v8_guest.json'), url);
      expect(guest.items, isEmpty);
      expect(guest.nextPageUrl, isNull);
      expect(guest.needLogin, isTrue);
      final off = favoriteThreadsFromApi({'ok': 0, 'error': 'message', 'message': '收藏功能已关闭', 'schema': 8}, url);
      expect(off.items, isEmpty);
      expect(off.needLogin, isFalse);
      // The wording tells the prompt when the forum does not (as the page parser reads it).
      expect(
        favoriteThreadsFromApi({'ok': 0, 'error': 'message', 'message': '请先登录', 'login': 0, 'uid': 0}, url).needLogin,
        isTrue,
      );
    });
  });

  group('the friends: friendListPageFromApi', () {
    final url = FriendRepository.listUrl(uid: '35');

    test('the own list: every field, the total, the owner, the next page; the garbage document is never read', () {
      expect(_raw('friend_v10_me.json'), contains(r'"document":"<div id=\"wp\">nothing</div>"'));
      final page = friendListPageFromApi(_json('friend_v10_me.json'), url);
      expect(page.items, hasLength(24));
      expect(page.totalCount, 25);
      expect(page.ownerName, 'ag_low2');
      expect(page.nextPageUrl, '$url&page=2');
      expect(page.message, isNull);
      expect(page.needLogin, isFalse);

      final first = page.items.first;
      expect(first.uid, '37');
      expect(first.username, 'ag_t01');
      expect(first.avatarUrl, '$baseUrl/data/avatar/noavatar.svg');
      expect(first.groupName, '字幕組', reason: 'the user group, not the recent note');
      expect(first.groupColor, isNull, reason: 'no color set for the group');
      expect(first.nameColor, isNull);
      expect(first.groupIconUrl, isNull, reason: 'the answer names no group icon');
      expect(first.credits, isNull, reason: 'the own list prints no credits');
      expect(page.items.map((e) => e.uid).take(3), ['37', '38', '39']);
      expect(page.items.map((e) => e.uid), contains('64'));
    });

    test("page 2 is the last; another member's list prints the credits; the empty list is a page", () {
      final p2 = friendListPageFromApi(_json('friend_v10_me_p2.json'), '$url&page=2');
      expect(p2.items.map((e) => e.uid), ['60']);
      expect(p2.totalCount, 25);
      expect(p2.nextPageUrl, isNull);

      final otherUrl = FriendRepository.listUrl(uid: '64');
      final other = friendListPageFromApi(_json('friend_v10_other.json'), otherUrl);
      expect(other.ownerName, '白洲アズサ');
      expect(other.totalCount, 1);
      expect(other.nextPageUrl, isNull);
      final friend = other.items.single;
      expect(friend.uid, '35');
      expect(friend.username, 'ag_low2');
      expect(friend.groupName, '低權組');
      expect(friend.credits, '1032', reason: 'the page prints "积分数: 1032" on another member\'s list');

      final empty = friendListPageFromApi(_json('friend_v10_empty.json'), FriendRepository.listUrl(uid: '31'));
      expect(empty.items, isEmpty);
      expect(empty.totalCount, 0);
      expect(empty.ownerName, 'ag_low');
      expect(empty.nextPageUrl, isNull);
      expect(empty.message, isNull);
    });

    test('a colored group colors the name and the group; a member who is gone, or without a uid, is dropped', () {
      final row = _rows('friend_v10_me.json', 'friends').first;
      final colored = Friend.fromApi({...row, 'groupcolor': '#FF0000'}, ownList: true)!;
      expect(colored.nameColor, '#FF0000');
      expect(colored.groupColor, '#FF0000');
      expect(Friend.fromApi({...row, 'username': '', 'anonymous': 1, 'avatar': ''}, ownList: true), isNull);
      expect(Friend.fromApi({...row, 'uid': 0}, ownList: true), isNull);
      expect(Friend.fromApi({...row, 'avatar': ''}, ownList: true)!.avatarUrl, isNull);
      expect(Friend.fromApi({...row, 'grouptitle': ''}, ownList: true)!.groupName, isNull);
      expect(Friend.fromApi(row, ownList: false)!.credits, '0', reason: "printed on another member's list");
      final page = friendListPageFromApi(
        _with('friend_v10_me.json', {
          'friends': [
            row,
            'not a row',
            {...row, 'uid': 0},
          ],
        }),
        url,
      );
      expect(page.items, hasLength(1));
      expect(page.totalCount, 25, reason: "the total is the forum's");
    });

    test('the guest message asks to log in; the friends switched off is the notice the page showed', () {
      final guest = friendListPageFromApi(_json('friend_v10_guest.json'), url);
      expect(guest.items, isEmpty);
      expect(guest.needLogin, isTrue);
      expect(guest.message, '请先登录后才能继续浏览');
      expect(guest.ownerName, isNull);
      expect(guest.nextPageUrl, isNull);
      final off = friendListPageFromApi({'ok': 0, 'error': 'message', 'message': '好友功能已关闭', 'schema': 10}, url);
      expect(off.items, isEmpty);
      expect(off.message, '好友功能已关闭');
      expect(off.needLogin, isFalse);
    });
  });

  group('the conversation: chatHistoryFromApi', () {
    test(
      'every field of a one-page conversation, newest first, the reply form; the garbage document is never read',
      () {
        expect(_raw('pm_v11_view.json'), contains(r'"document":"<div id=\"wp\">nothing</div>"'));
        final info = chatHistoryFromApi(_json('pm_v11_view.json'))!;
        expect(info.username, 'ag_low');
        expect(info.messageCount, 8);
        expect(info.previousPage, isNull, reason: 'one page');
        expect(info.nextPage, isNull);
        expect(info.messages, hasLength(8));

        final rows = _rows('pm_v11_view.json', 'messages');
        expect(
          rows.first['dateline'] as int,
          lessThan(rows.last['dateline'] as int),
          reason: 'the forum lists oldest first',
        );
        final newest = info.messages.first;
        expect(newest.dateTime, _at(1790957118), reason: 'the page parser lists newest first');
        expect(newest.author, 'ag_low');
        expect(newest.authorUid, '31');
        final oldest = info.messages.last;
        expect(oldest.author, 'ag_low2', reason: "the member's name, not the page's 您");
        expect(oldest.authorUid, '35');
        expect(oldest.authorAvatarUrl, '$baseUrl/data/avatar/noavatar.svg');
        expect(oldest.message, 'BU 試用：B 私訊 A（1789151263072）');
        expect(oldest.dateTime, _at(1789151446));
        expect(oldest.dateOnly, isFalse);

        final target = info.sendTarget!;
        expect(
          target.targetUrl,
          '$baseUrl/home.php?mod=spacecp&ac=pm&op=send&pmid=507149&daterange=0&handlekey=pmsend&pmsubmit=yes'
          '&inajax=1&topmuid=31',
          reason: "the page's form action with inajax and the hidden topmuid, as the page parser built it",
        );
        expect(target.pmid, '507149');
        expect(target.formHash, 'f1f2f3f4');
      },
    );

    test('page 3 of 4: the older page before, the next after; the html of a message kept; the last page without a '
        'page asked', () {
      final info = chatHistoryFromApi(_json('pm_v11_view_p2.json'))!;
      expect(info.username, '字幕組');
      expect(info.messageCount, 37);
      expect(info.previousPage, 2);
      expect(info.nextPage, 4);
      expect(info.messages, hasLength(10));
      final linked = info.messages.firstWhere((e) => e.message.endsWith('cnqsuh'));
      expect(
        linked.message,
        [
          '<a href="$baseUrl/forum.php?mod=redirect&amp;goto=findpost&amp;pid=3955&amp;ptid=9199345" target="_blank">',
          '<strong>关于您在“[Rulebot multi fixture 20260930-101846] FID2 版規問答測試”的帖子</strong></a><br />\n',
          '看這帖 [​b]粗[​/b] cnqsuh',
        ].join(),
        reason: 'the html the forum printed, as the page parser cut it',
      );
      expect(info.sendTarget!.pmid, '507220', reason: 'the first message of the page');
      expect(info.sendTarget!.targetUrl, endsWith('&inajax=1&topmuid=36'));

      // The forum serves the last page when none is asked: older messages are on page - 1, nothing after.
      final last = chatHistoryFromApi(_with('pm_v11_view_p2.json', {'page': 4, 'has_next': 0}))!;
      expect(last.previousPage, 3);
      expect(last.nextPage, isNull);
      final firstPage = chatHistoryFromApi(_with('pm_v11_view_p2.json', {'page': 1, 'has_next': 1}))!;
      expect(firstPage.previousPage, isNull);
      expect(firstPage.nextPage, 2);
    });

    test('a group conversation names its subject and no peer; no conversation yet: no messages, no form', () {
      final chat = chatHistoryFromApi(_json('pm_v11_view_chat.json'))!;
      expect(chat.username, 'BU pm 群聊 GC1 B 發起（1789176308198）');
      expect(chat.messageCount, 9);
      expect(chat.messages, hasLength(9));
      expect(chat.messages.map((e) => e.author), contains('ag_mid'));
      expect(chat.messages.firstWhere((e) => e.author == 'ag_mid').authorUid, '33');
      expect(chat.sendTarget!.targetUrl, isNot(contains('topmuid')), reason: 'no peer in a group');
      expect(chat.sendTarget!.pmid, '507155');

      final empty = chatHistoryFromApi(_json('pm_v11_empty.json'))!;
      expect(empty.username, 'Blue Bird');
      expect(empty.messageCount, 0);
      expect(empty.messages, isEmpty);
      expect(empty.sendTarget, isNull, reason: 'the page prints no form');
      expect(empty.previousPage, isNull);
      expect(empty.nextPage, isNull);
    });

    test('a message without an author is dropped; the plain text escaped when the html is missing; no form without '
        'a hash', () {
      final row = _rows('pm_v11_view.json', 'messages').first;
      expect(ChatMessage.fromApi({...row, 'fromuid': 0, 'from': ''}), isNull);
      final gone = ChatMessage.fromApi({...row, 'fromuid': 0, 'from': 'someone'})!;
      expect(gone.author, 'someone');
      expect(gone.authorUid, isNull);
      final nameless = ChatMessage.fromApi({...row, 'from': '', 'avatar': ''})!;
      expect(nameless.author, isNull, reason: 'a member who is not there any more');
      expect(nameless.authorUid, '35');
      expect(nameless.authorAvatarUrl, isNull);
      expect(ChatMessage.fromApi({...row, 'message_html': '', 'message': 'a < b\nc'})!.message, 'a &lt; b<br />c');
      expect(ChatMessage.fromApi({...row, 'dateline': 0})!.dateTime, isNull);

      final info = chatHistoryFromApi(
        _with('pm_v11_view.json', {
          'messages': [
            row,
            'not a row',
            {...row, 'fromuid': 0, 'from': ''},
          ],
        }),
      )!;
      expect(info.messages, hasLength(1));
      expect(info.messageCount, 8, reason: "the count is the forum's");
      expect(chatHistoryFromApi(_with('pm_v11_view.json', {'formhash': ''}))!.sendTarget, isNull);
      expect(chatHistoryFromApi(_with('pm_v11_view.json', {'reply': null}))!.sendTarget, isNull);
      expect(
        chatHistoryFromApi(
          _with('pm_v11_view.json', {
            'reply': {'action': '', 'pmid': 1, 'topmuid': 31},
          }),
        )!.sendTarget,
        isNull,
      );
    });

    test(
      'the forum message (a guest, the private messages switched off) is no conversation, as the page parsed to',
      () {
        expect(chatHistoryFromApi(_json('pm_v11_guest.json')), isNull);
        expect(chatHistoryFromApi({'ok': 0, 'error': 'message', 'message': '短消息功能已关闭', 'schema': 11}), isNull);
      },
    );
  });

  group('the credit log: pointsChangelogFromApi', () {
    test(
      'every field of the first page: the changes, the pagination, the filters; the garbage document is never read',
      () {
        expect(_raw('credit_v12_log.json'), contains(r'"document":"<div id=\"wp\">nothing</div>"'));
        final page = pointsChangelogFromApi(_json('credit_v12_log.json'))!;
        expect(page.changes, hasLength(20));
        expect(page.currentPage, 1);
        expect(page.totalPages, 40);

        final first = page.changes.first;
        expect(first.operation, '积分规则');
        expect(first.operationFilterUrl, 'home.php?mod=spacecp&ac=credit&op=log&optype=RUL');
        expect(first.changeMap, {'天使币': '+2'});
        expect(first.changeMapString, '天使币 +2', reason: 'as the page prints the change');
        expect(first.pointsChangeType, PointsChangeType.more);
        expect(first.detail, '<td>每天登录</td>', reason: 'the cell the page parser kept, the text escaped');
        expect(first.redirectUrl, isNull);
        expect(first.time, _at(1792512427), reason: 'the exact second');
        expect(page.changes[1].detail, '<td>发表回复(fid:10)</td>');
        expect(page.changes[1].time, _at(1792446315));

        final filters = page.allParameters;
        expect(filters.extTypeList.map((e) => e.name), ['不限', '威望', '天使币', '宣传', '腹黑', '天然', '精灵']);
        expect(filters.extTypeList.map((e) => e.extType), ['0', '1', '2', '3', '4', '5', '6']);
        expect(filters.changeTypeList.map((e) => (e.name, e.changeType)), [('不限', '0'), ('支出', '-1'), ('收入', '1')]);
        expect(filters.operationTypeList, hasLength(37));
        expect(
          filters.operationTypeList.first,
          const ChangelogOperationType(name: creditLogAnyOperationName, operation: ''),
          reason: "the choice of no operation first, as the page's form lists it and the query form starts on it",
        );
        expect(filters.operationTypeList[1], const ChangelogOperationType(name: '任务奖励', operation: 'TRC'));
        expect(filters.operationTypeList, contains(const ChangelogOperationType(name: '积分规则', operation: 'RUL')));
        // The web form of the page gives the same first choice.
        final web = parseAllParameters(parseHtmlDocument(_creditLogPage()));
        expect(web.operationTypeList.first.operation, '');
        expect(web.operationTypeList.first.name, creditLogAnyOperationName);
        expect(filters.toMap().keys, web.toMap().keys);
      },
    );

    test('page 2; the filtered page: the rated posts link their post, the html of the detail escaped', () {
      final p2 = pointsChangelogFromApi(_json('credit_v12_log_p2.json'))!;
      expect(p2.changes, hasLength(20));
      expect(p2.currentPage, 2);
      expect(p2.totalPages, 40);
      expect(p2.changes.first.operation, '积分规则');
      expect(p2.changes.first.time, _at(1792302791));
      expect(p2.changes.first.detail, '<td>发表主题(fid:14)</td>');

      final filtered = pointsChangelogFromApi(_json('credit_v12_log_filter.json'))!;
      expect(filtered.changes, hasLength(20));
      expect(filtered.currentPage, 1);
      expect(filtered.totalPages, 2);
      final first = filtered.changes.first;
      expect(first.operation, '帖子被评分');
      expect(first.operationFilterUrl, 'home.php?mod=spacecp&ac=credit&op=log&optype=PRC');
      expect(first.changeMap, {'威望': '+5'});
      expect(first.pointsChangeType, PointsChangeType.more);
      expect(first.redirectUrl, '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=3942');
      expect(first.detail, '<td>[Rulebot multi fixture 20260930-101846] FID2 版規問答測試 被评分获得的积分</td>');
      expect(first.time, _at(1791601872));
      final tagged = filtered.changes[1];
      expect(tagged.changeMap, {'精灵': '+9'});
      expect(tagged.detail, contains('RTK驗收帖 &lt;i&gt;&amp;"{_G/config/db/1/dbpw} Re: 039768'));
      expect(parseHtmlDocument(tagged.detail).body!.text, contains('RTK驗收帖 <i>&"{_G/config/db/1/dbpw}'));
      expect(filtered.allParameters.operationTypeList, hasLength(37));
    });

    test('an expense, a mixed change, a reset, a record without a code; a row without an operation or a time is '
        'dropped', () {
      final row = _rows('credit_v12_log.json', 'logs').first;
      Map<String, Object?> change(String title, int value, [String? text]) => {
        'id': 2,
        'title': title,
        'value': value,
        'text': ?text,
      };
      final expense = PointsChange.fromApi({
        ...row,
        'type': 'expense',
        'changes': [change('天使币', -5, '天使币 -5')],
      })!;
      expect(expense.pointsChangeType, PointsChangeType.less);
      expect(expense.changeMap, {'天使币': '-5'});

      final mixed = PointsChange.fromApi({
        ...row,
        'type': 'mixed',
        'changes': [change('天使币', -5, '天使币 -5'), change('威望', 1, '威望 +1')],
      })!;
      expect(mixed.pointsChangeType, PointsChangeType.less, reason: 'by the first credit, as the page parser');
      expect(mixed.changeMap, {'天使币': '-5', '威望': '+1'});
      expect(mixed.changeMapString, '天使币 -5,威望 +1');
      expect(
        PointsChange.fromApi({
          ...row,
          'type': 'mixed',
          'changes': [change('威望', 1, '威望 +1'), change('天使币', -5, '天使币 -5')],
        })!.pointsChangeType,
        PointsChangeType.more,
      );
      expect(
        PointsChange.fromApi({...row, 'type': '', 'changes': <Object?>[]})!.pointsChangeType,
        PointsChangeType.unlimited,
      );

      final reset = PointsChange.fromApi({
        ...row,
        'type': 'expense',
        'changes': [change('天使币', -675, '天使币清零')],
      })!;
      expect(reset.changeMap, {'天使币': '清零'}, reason: 'as the page prints a reset');
      expect(reset.changeMapString, '天使币 清零');
      // Without the printed text: the signed value.
      expect(
        PointsChange.fromApi({
          ...row,
          'changes': [change('天使币', 3), change('威望', -3)],
        })!.changeMap,
        {'天使币': '+3', '威望': '-3'},
      );

      final manual = PointsChange.fromApi({...row, 'operation': '手动变更', 'optype': '', 'filter_url': ''})!;
      expect(manual.operation, '手动变更');
      expect(manual.operationFilterUrl, isEmpty, reason: 'the page prints no link for a record without a code');

      expect(PointsChange.fromApi({...row, 'operation': ''}), isNull);
      expect(PointsChange.fromApi({...row, 'dateline': 0}), isNull);
      final page = pointsChangelogFromApi(
        _with('credit_v12_log.json', {
          'logs': [
            {...row, 'operation': ''},
            {...row, 'dateline': 0},
            row,
            'not a row',
          ],
        }),
      )!;
      expect(page.changes, hasLength(1));
      expect(page.totalPages, 40, reason: "the pagination is the forum's");
      // A page without pages: one page.
      final bare = pointsChangelogFromApi(_with('credit_v12_log.json', {'page': 0, 'pages': 0}))!;
      expect((bare.currentPage, bare.totalPages), (1, 1));
    });

    test('the guest message is no log, as the message page parsed to; its filters are empty', () {
      expect(pointsChangelogFromApi(_json('credit_v12_guest.json')), isNull);
      final filters = changelogParametersFromApi(_json('credit_v12_guest.json'));
      expect(filters.extTypeList, isEmpty);
      expect(filters.changeTypeList, isEmpty);
      expect(filters.operationTypeList, isEmpty);
    });
  });

  group('the repositories and the blocs', () {
    _Answer favoriteAnswer(RequestOptions o) => _api(
      _raw(switch ((o.uri.queryParameters['type'], o.uri.queryParameters['page'])) {
        ('forum', _) => 'favorite_v8_forum.json',
        (_, '2') => 'favorite_v8_thread_p2.json',
        _ => 'favorite_v8_thread.json',
      }),
    );

    test(
      'the favorites: both kinds from the fields, the next page, the bloc, the record looked up; lean requests',
      () async {
        final forum = _Forum(favoriteAnswer);
        _use(forum);
        final repo = FavoriteRepository();
        final threads = _right(await repo.fetchListPage().run());
        expect(threads.items, hasLength(20));
        expect(threads.nextPageUrl, '${FavoriteRepository.listUrl}&page=2');
        final p2 = _right(await repo.fetchListPageOf(FavoriteType.thread, threads.nextPageUrl).run());
        expect(p2.items.map((e) => e.favid), ['251']);
        expect(p2.nextPageUrl, isNull);
        final forums = _right(await repo.fetchForumListPage().run());
        expect(forums.items.map((e) => e.fid), ['13', '2']);
        expect(forum.requests, hasLength(3));
        expect(forum.requests[1].uri.queryParameters, containsPair('page', '2'));
        expect(forum.requests.every(_asksLean), isTrue);

        final bloc = FavoriteBloc(favoriteRepository: repo, authenticationRepository: _Auth())
          ..add(const FavoriteLoadRequested());
        var state = await bloc.stream.firstWhere((s) => s.status != FavoriteStatus.loading);
        expect(state.status, FavoriteStatus.success);
        expect(state.items, hasLength(20));
        expect(state.nextPageUrl, isNotNull);
        bloc.add(const FavoriteLoadMoreRequested());
        state = await bloc.stream.firstWhere((s) => s.pageNumber == 2);
        expect(state.items, hasLength(21));
        expect(state.nextPageUrl, isNull);
        await bloc.close();
        expect(repo.cachedFavid(uid: 35, tid: '9199849'), '251', reason: 'the records seen are remembered');

        // The record of a thread on the last page: the list walked from the fields.
        final found = FavoriteRepository();
        expect(_right(await found.findFavid(tid: '9199849', uid: 35).run()), '251');
        expect(_right(await found.findForumFavid(fid: '2', uid: 35).run()), '272');
        expect(_right(await found.findFavid(tid: '1', uid: 35, maxPages: 2).run()), isNull);
        await repo.dispose();
        await found.dispose();
      },
    );

    test('the favorites: the guest message asks to log in; the old answers as before', () async {
      _use(_Forum.always(_api(_raw('favorite_v8_guest.json'))));
      final repo = FavoriteRepository();
      expect(_right(await repo.fetchListPage().run()).needLogin, isTrue);
      final bloc = FavoriteBloc(favoriteRepository: repo, authenticationRepository: _Auth())
        ..add(const FavoriteLoadRequested());
      final state = await bloc.stream.firstWhere((s) => s.status != FavoriteStatus.loading);
      await bloc.close();
      expect(state.status, FavoriteStatus.needLogin);

      // The web page, and an older plugin's answer carrying it, are the document parsed as before.
      final html = _page('favorite_list_x5.html');
      final web = parseFavoriteListPage(parseHtmlDocument(html));
      expect(web.items, hasLength(2));
      for (final (label, answer) in [('the web page', _html(html)), ('plugin 1.6.0', _oldApi(html, 'favorite'))]) {
        _use(_Forum.always(answer));
        final page = _right(await FavoriteRepository().fetchListPage().run());
        expect(page.items.map(_fav), web.items.map(_fav), reason: label);
        expect(page.nextPageUrl, web.nextPageUrl, reason: label);
        final typed = _right(await FavoriteRepository().fetchListPageOf(FavoriteType.thread).run());
        expect(typed.items.map(_fav), web.items.map(_fav), reason: label);
      }
      final forumHtml = _page('favorite_forum_list_x5.html');
      final webForums = parseFavoriteForumListPage(parseHtmlDocument(forumHtml));
      expect(webForums.items, isNotEmpty);
      _use(_Forum.always(_oldApi(forumHtml, 'favorite')));
      expect(_right(await FavoriteRepository().fetchForumListPage().run()).items.map(_fav), webForums.items.map(_fav));
      await repo.dispose();
    });

    test(
      'the friends: the list from the fields, the next page, the bloc, the @ candidates; the old answers as before',
      () async {
        final forum = _Forum(
          (o) => _api(_raw(o.uri.queryParameters['page'] == '2' ? 'friend_v10_me_p2.json' : 'friend_v10_me.json')),
        );
        _use(forum);
        final url = FriendRepository.listUrl(uid: '35');
        final page = _right(await const FriendRepository().fetchPage(url).run());
        expect(page.items, hasLength(24));
        expect(page.totalCount, 25);
        expect(page.ownerName, 'ag_low2');
        expect(page.nextPageUrl, '$url&page=2');

        final bloc = FriendBloc(friendRepository: const FriendRepository(), firstPageUrl: url)
          ..add(const FriendLoadRequested());
        var state = await bloc.stream.firstWhere((s) => s.status != FriendStatus.loading);
        expect(state.status, FriendStatus.success);
        expect(state.items, hasLength(24));
        expect(state.totalCount, 25);
        expect(state.ownerName, 'ag_low2');
        bloc.add(const FriendLoadMoreRequested());
        state = await bloc.stream.firstWhere((s) => s.pageNumber == 2);
        expect(state.items, hasLength(25));
        expect(state.nextPageUrl, isNull);
        await bloc.close();
        expect(forum.requests.last.uri.queryParameters, containsPair('page', '2'));
        expect(forum.requests.every(_asksLean), isTrue);

        // The `@` candidates walk the own list the same way.
        final candidates = _right(await MentionRepository().loadOwnFriends(selfUid: '35').run());
        expect(candidates.friends, hasLength(25));
        expect(candidates.friends.first.username, 'ag_t01');
        expect(candidates.message, isNull);

        // The guest: asked to log in.
        _use(_Forum.always(_api(_raw('friend_v10_guest.json'))));
        final guest = FriendBloc(friendRepository: const FriendRepository(), firstPageUrl: url)
          ..add(const FriendLoadRequested());
        final guestState = await guest.stream.firstWhere((s) => s.status != FriendStatus.loading);
        await guest.close();
        expect(guestState.status, FriendStatus.needLogin);

        // The web page, an older plugin's answer carrying it, and the privacy page plugin 2.5.0 still answers as
        // blocks: the document parsed as before.
        final html = _page('friend_list_x5.html');
        final web = parseFriendListPage(parseHtmlDocument(html));
        expect(web.items, isNotEmpty);
        for (final (label, answer) in [('the web page', _html(html)), ('plugin 1.6.0', _oldApi(html, 'friend'))]) {
          _use(_Forum.always(answer));
          final old = _right(await const FriendRepository().fetchPage(FriendRepository.listUrl(uid: '1001')).run());
          expect(old.items.map((e) => e.toMap()), web.items.map((e) => e.toMap()), reason: label);
          expect((old.totalCount, old.ownerName, old.nextPageUrl), (web.totalCount, web.ownerName, web.nextPageUrl));
        }
        final privacy = _page('friend_list_privacy_x5.html');
        _use(_Forum.always(_oldApi(privacy, 'friend')));
        final blocked = _right(await const FriendRepository().fetchPage(FriendRepository.listUrl(uid: '1001')).run());
        expect(blocked.items, isEmpty);
        expect(blocked.message, parseFriendListPage(parseHtmlDocument(privacy)).message);
        expect(blocked.message, isNotNull);
        expect(blocked.needLogin, isFalse);
      },
    );

    test('the conversation: the last page first, then the older page, the bloc; the old answers as before', () async {
      // Without a page the forum serves the last page (4 of 4 here); page 3 is the one before.
      final forum = _Forum(
        (o) => _api(switch (o.uri.queryParameters['page']) {
          '3' => _json('pm_v11_view_p2.json'),
          null => _with('pm_v11_view_p2.json', {'page': 4, 'has_next': 0}),
          final other => fail('unexpected page $other'),
        }),
      );
      _use(forum);
      expect(_right(await const ChatRepository().fetchChatHistory('36').run()), isA<TsdmAppStructuredPage>());

      final bloc = ChatHistoryBloc(const ChatRepository())
        ..add(const ChatHistoryLoadHistoryRequested(uid: '36', page: null));
      var state = await bloc.stream.firstWhere((s) => s.status == ChatHistoryStatus.success);
      expect(state.user.username, '字幕組');
      expect(state.messageCount, 37);
      expect(state.messages, hasLength(10));
      expect(state.pageNumber, isNull);
      expect(state.previousPage, 3);
      expect(state.nextPage, isNull);
      expect(state.sendTarget?.pmid, '507220');
      expect(state.sendTarget?.formHash, 'f1f2f3f4');

      bloc.add(ChatHistoryLoadHistoryRequested(uid: '36', page: state.previousPage));
      state = await bloc.stream.firstWhere((s) => s.status == ChatHistoryStatus.success && s.pageNumber == 3);
      expect(state.messages, hasLength(20), reason: 'the older page appended');
      expect(state.previousPage, 2);
      expect(state.nextPage, 4);
      await bloc.close();
      expect(forum.requests, hasLength(3));
      expect(forum.requests.last.uri.queryParameters, containsPair('page', '3'));
      expect(forum.requests.every(_asksLean), isTrue);

      // The guest: no conversation, a failure as the message page was.
      _use(_Forum.always(_api(_raw('pm_v11_guest.json'))));
      final guest = ChatHistoryBloc(const ChatRepository())
        ..add(const ChatHistoryLoadHistoryRequested(uid: '36', page: null));
      final guestState = await guest.stream.firstWhere((s) => s.status != ChatHistoryStatus.loading);
      await guest.close();
      expect(guestState.status, ChatHistoryStatus.failure);

      // The web page, and an older plugin's answer carrying it, are the document parsed as before.
      final html = _page('chat_history_bare_url_x5.html');
      final web = parseChatHistory(parseHtmlDocument(html))!;
      expect(web.messages, hasLength(2));
      for (final (label, answer) in [('the web page', _html(html)), ('plugin 1.3.0', _oldApi(html, 'pm'))]) {
        _use(_Forum.always(answer));
        expect(
          _right(await const ChatRepository().fetchChatHistory('1001').run()),
          isA<TsdmAppWebPage>(),
          reason: label,
        );
        final b = ChatHistoryBloc(const ChatRepository())
          ..add(const ChatHistoryLoadHistoryRequested(uid: '1001', page: null));
        final s = await b.stream.firstWhere((s) => s.status != ChatHistoryStatus.loading);
        await b.close();
        expect(s.status, ChatHistoryStatus.success, reason: label);
        expect(s.messages.map((e) => e.toMap()), web.messages.map((e) => e.toMap()), reason: label);
        expect(s.sendTarget?.toMap(), web.sendTarget?.toMap(), reason: label);
        expect(s.user.username, web.username, reason: label);
      }
    });

    test('the credit log: the changes and the filters from the fields, the next page, the bloc; the old answers as '
        'before', () async {
      final forum = _Forum(
        (o) => _api(_raw(o.uri.queryParameters['page'] == '2' ? 'credit_v12_log_p2.json' : 'credit_v12_log.json')),
      );
      _use(forum);
      expect(
        _right(await PointsRepository().fetchChangelogPage(const ChangelogParameter.empty()).run()),
        isA<TsdmAppStructuredPage>(),
      );

      final bloc = PointsChangelogBloc(pointsRepository: PointsRepository())..add(PointsChangelogRefreshRequested());
      var state = await bloc.stream.firstWhere((s) => s.status != PointsStatus.loading);
      expect(state.status, PointsStatus.success);
      expect(state.fullChangelog, hasLength(20));
      expect(state.currentPage, 1);
      expect(state.totalPages, 40);
      expect(state.allParameters.extTypeList, hasLength(7));
      expect(state.allParameters.operationTypeList.first.operation, '');
      expect(state.allParameters.operationTypeList, hasLength(37));
      expect(state.allParameters.changeTypeList, hasLength(3));

      bloc.add(const PointsChangelogLoadMoreRequested(1));
      state = await bloc.stream.firstWhere((s) => s.currentPage == 2);
      expect(state.fullChangelog, hasLength(40));
      expect(state.fullChangelog[20].time, _at(1792302791));
      expect(state.totalPages, 40);
      await bloc.close();
      expect(forum.requests, hasLength(3));
      expect(forum.requests.last.uri.queryParameters, containsPair('page', '2'));
      expect(forum.requests.last.uri.queryParameters, containsPair('op', 'log'));
      expect(forum.requests.every(_asksLean), isTrue);

      // The query with filters: the parameters in the url as before, the filtered answer built the same.
      _use(_Forum.always(_api(_raw('credit_v12_log_filter.json'))));
      final filtered = PointsChangelogBloc(pointsRepository: PointsRepository())
        ..add(
          const PointsChangelogQueryRequested(
            ChangelogParameter(
              extType: '0',
              operation: 'PRC',
              changeType: '1',
              startTime: '',
              endTime: '',
              pageNumber: 1,
            ),
          ),
        );
      final filteredState = await filtered.stream.firstWhere((s) => s.status != PointsStatus.loading);
      await filtered.close();
      expect(filteredState.status, PointsStatus.success);
      expect(filteredState.fullChangelog, hasLength(20));
      expect(filteredState.fullChangelog.first.operation, '帖子被评分');
      expect(filteredState.totalPages, 2);

      // The guest: a failure, as the message page without the table was.
      _use(_Forum.always(_api(_raw('credit_v12_guest.json'))));
      final guest = PointsChangelogBloc(pointsRepository: PointsRepository())..add(PointsChangelogRefreshRequested());
      final guestState = await guest.stream.firstWhere((s) => s.status != PointsStatus.loading);
      await guest.close();
      expect(guestState.status, PointsStatus.failed);

      // The web page, and an older plugin's answer carrying it, are the document parsed as before.
      final html = _creditLogPage();
      final web = buildChangeListFromTable(parseHtmlDocument(html).querySelector('table.dt')!);
      expect(web, hasLength(2));
      for (final (label, answer) in [('the web page', _html(html)), ('plugin 1.7.0', _oldApi(html, 'credit'))]) {
        _use(_Forum.always(answer));
        expect(
          _right(await PointsRepository().fetchChangelogPage(const ChangelogParameter.empty()).run()),
          isA<TsdmAppWebPage>(),
          reason: label,
        );
        final b = PointsChangelogBloc(pointsRepository: PointsRepository())..add(PointsChangelogRefreshRequested());
        final s = await b.stream.firstWhere((s) => s.status != PointsStatus.loading);
        await b.close();
        expect(s.status, PointsStatus.success, reason: label);
        expect(s.fullChangelog.map(_change), web.map(_change), reason: label);
        expect((s.currentPage, s.totalPages), (1, 3), reason: label);
        expect(s.allParameters.operationTypeList.map((e) => e.operation), ['', 'RPC'], reason: label);
      }
      // The statistics page (`op=base`) is still the document.
      _use(_Forum.always(_api({'ok': 1, 'api': 1, 'type': 'credit', 'page': 1, 'document': _bodyOf(html)})));
      expect(_right(await PointsRepository().fetchStatisticsPage().run()).querySelector('table.dt'), isNotNull);
    });

    test('an answer without a page is a failed request, as before', () async {
      _use(_Forum.always(_api({'ok': 0, 'error': 'internal'})));
      final favorites = FavoriteRepository();
      expect((await favorites.fetchListPage().run()).getLeft().toNullable(), isA<HttpRequestFailedException>());
      await favorites.dispose();
      expect(
        (await const FriendRepository().fetchPage(FriendRepository.listUrl(uid: '35')).run()).getLeft().toNullable(),
        isA<HttpRequestFailedException>(),
      );
      expect(
        (await const ChatRepository().fetchChatHistory('36').run()).getLeft().toNullable(),
        isA<HttpRequestFailedException>(),
      );
      expect(
        (await PointsRepository().fetchChangelogPage(const ChangelogParameter.empty()).run()).getLeft().toNullable(),
        isA<HttpRequestFailedException>(),
      );
    });
  });
}
