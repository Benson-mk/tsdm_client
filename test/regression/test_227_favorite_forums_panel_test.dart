/// The "我收藏的版块" panel of the topics tab (版块) built from the homepage answer of the forum's app API.
///
/// Before, the panel looked each id of `favorite_forums` up among the forums of the categories: a favorite subforum
/// (listed by id and name only, if at all) showed the default icon, 0 / 0 / 0 and no latest thread, and a forum with
/// subforums showed the counts of the categories, which add the subforums' (the web page's panel prints the forum's
/// own). Plugin 2.8.1 answers the panel as the page prints it (`favorites`): the cards are built from it. An older
/// plugin (2.3.0 to 2.8.0) names the favorites by id only: when it names any, the shared repository asks the page once
/// more without `nodoc=1`, and the panel is read from the `document` of that answer, as the web page shows it. A plugin
/// 2.8.1, a guest and a member without favorites cost no request more; the web page path is untouched.
///
/// Test data:
/// * `tsdmapp/index_v5_favorites.json`: plugin 2.8.1, from the plugin's fixture tool (group `index_fav`): the test
///   forum's account ag_low2 favorited a subforum (15, under 2, with an icon and a description), a forum with that
///   subforum (2), a forum hidden from them (26, the forum hides such forums: `hideprivate`), a forum (7), a link
///   forum (29) and a group's forum (28).
/// * `index_favorites_panel_x5.json`: the same page of the same moment asked without `nodoc=1` (the answer keeps its
///   `document`), trimmed to the fields the panel needs and the document to the panel (the grid of six favorites;
///   the forum's host and name as in the other samples).
/// * `forum_index_x5.html`: the production web page, a panel of one favorite in the list layout.
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/topics/bloc/topics_bloc.dart';
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
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:universal_html/parsing.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/data/$path').readAsStringSync()) as Map<String, dynamic>;

/// The answer of plugin 2.8.1 of the fixture (lean).
Map<String, dynamic> _plugin281() => _json('tsdmapp/index_v5_favorites.json');

/// The answer of the same moment asked with its document (plugin 2.8.1: `favorites` and the panel in `document`).
Map<String, dynamic> _withDocument() => _json('index_favorites_panel_x5.json');

/// [json] as plugin 2.3.0 to 2.8.0 answers it: no `favorites`.
Map<String, dynamic> _older(Map<String, dynamic> json) => {...json}..remove('favorites');

/// [json] asked lean (`nodoc=1`): no `document`.
Map<String, dynamic> _lean(Map<String, dynamic> json) => {...json}..remove('document');

/// The forums of the panel (the first group) of [json], none when there is no panel.
List<Forum> _panel(Map<String, dynamic> json) =>
    forumGroupsFromApi(json).where((e) => e.isFavorites).firstOrNull?.forumList ?? const [];

/// The forum [fid] among the categories of [json] (not the panel).
Forum _inCategories(Map<String, dynamic> json, int fid) => forumGroupsFromApi(
  json,
).where((e) => !e.isFavorites).expand((e) => e.forumList).firstWhere((e) => e.forumID == fid);

/// The forum's wall clock (UTC+8) of a time the app API gives, to the minute: the web page prints the time so.
(int, int, int, int, int) _wallMinute(DateTime time) {
  final wall = time.toUtc().add(const Duration(hours: 8));
  return (wall.year, wall.month, wall.day, wall.hour, wall.minute);
}

/// The time the web page printed, read by its reader as the wall clock of the forum, to the minute.
(int, int, int, int, int) _pageMinute(DateTime time) => (time.year, time.month, time.day, time.hour, time.minute);

const _viewer = UserLoginInfo(uid: 35, username: 'ag_low2');

/// One answer of the fake forum.
typedef _Answer = ({String body, bool json, int status});

_Answer _api(Object answer, {int status = 200}) =>
    (body: answer is String ? answer : jsonEncode(answer), json: true, status: status);

/// A forum answering the homepage asked lean (`nodoc=1`) with [lean] and asked with its document with [full],
/// recording every request; [onFull] runs when the page with its document is asked, before it is answered.
final class _Forum implements HttpClientAdapter {
  _Forum({required this.lean, _Answer Function()? full, this.onFull}) : full = full ?? lean;

  _Answer Function() lean;
  _Answer Function() full;
  void Function()? onFull;
  final requests = <RequestOptions>[];

  List<RequestOptions> get homepage => requests.where((e) => e.uri.path == '/forum.php').toList();

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    requests.add(options);
    final query = options.uri.queryParameters;
    if (options.uri.path != '/forum.php' || query['tsdmapp'] != 'json') {
      return ResponseBody.fromString('unexpected', 404);
    }
    final _Answer a;
    if (query['nodoc'] == '1') {
      a = lean();
    } else {
      onFull?.call();
      a = full();
    }
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

/// Authentication repository of [user].
final class _FakeAuth extends AuthenticationRepository {
  _FakeAuth(this.user);

  UserLoginInfo? user;
  final subject = BehaviorSubject<AuthStatus>();

  @override
  UserLoginInfo? get currentUser => user;

  @override
  Stream<AuthStatus> get status => subject.stream;

  @override
  Future<void> dispose() async {
    await subject.close();
    await super.dispose();
  }
}

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

/// The list layout of the panel (up to three favorites) as the forum's template prints it: a forum with its latest
/// thread, a forum the viewer may not enter ("私密版块") and a link forum ("链接到外部地址", no counts).
const _listLayoutPage = '''
<html><body><div id="wp" class="wp"><div id="ct" class="wp cl"><div class="mn"><div class="fl bm">
<div class="bm bmw  cl">
<div class="bm_h cl"><h2><a href="home.php?mod=space&amp;do=favorite&amp;type=forum">我收藏的版块</a></h2></div>
<div id="category_0" class="bm_c" style="">
<table cellspacing="0" cellpadding="0" class="fl_tb">
<tr><td class="fl_icn"><a href="forum.php?mod=forumdisplay&fid=7" title="神作殿堂"><img src="data/attachment/common/7.png" alt="神作殿堂" /></a></td>
<td>
<h2><a href="forum.php?mod=forumdisplay&fid=7">神作殿堂</a><em class="xw0 xi1" title="今日"> (3)</em></h2>
<p class="xg2">经典神作回顾与安利推荐</p>
</td>
<td class="fl_i"><span class="xi2">27</span><span class="xg1"> / <span title="12300">1万</span></span></td>
<td class="fl_by">
<div>
<a href="forum.php?mod=redirect&amp;tid=9199201&amp;goto=lastpost#lastpost" class="xi2">ATP JSON 89328</a> <cite>2026-9-23 21:58 <a href="home.php?mod=space&username=ag_low2">ag_low2</a></cite>
</div>
</td>
</tr>
<tr class="fl_row">
<td class="fl_icn"><a href="forum.php?mod=forumdisplay&fid=26" title="BU 黑名單權限版 G"><img src="data/attachment/common/26.png" alt="BU 黑名單權限版 G" /></a></td>
<td>
<h2><a href="forum.php?mod=forumdisplay&fid=26">BU 黑名單權限版 G</a></h2>
</td>
<td class="fl_i"><span class="xi2">10</span><span class="xg1"> / 10</span></td>
<td class="fl_by">
<div>
私密版块
</div>
</td>
</tr>
<tr class="fl_row">
<td class="fl_icn"><a href="forum.php?mod=forumdisplay&fid=29" target="_blank" title="BU 通知驗收版 H"><img src="template/discuzx5/static//images/forum.png" alt="BU 通知驗收版 H" /></a></td>
<td>
<h2><a href="forum.php?mod=forumdisplay&fid=29" target="_blank">BU 通知驗收版 H</a></h2>
</td>
<td class="fl_i">
</td>
<td class="fl_by">
<div>
<a href="forum.php?mod=forumdisplay&fid=29" class="xi2">链接到外部地址</a>
</div>
</td>
</tr>
<tr class="fl_row">
</tr>
</table>
</div>
</div>
</div></div></div></div></body></html>
''';

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('plugin 2.8.1: the panel is the favorites of the answer', () {
    test('every favorite in the order of the page, first; a favorite subforum with all of its data', () {
      final json = _plugin281();
      final groups = forumGroupsFromApi(json);
      expect(groups.first.isFavorites, isTrue);
      expect(groups.first.name, '我收藏的版块');
      expect(groups.first.url, 'home.php?mod=space&do=favorite&type=forum');
      expect(groups.first.forumList.map((e) => e.forumID), [15, 2, 26, 7, 29, 28]);
      expect(groups.skip(1).where((e) => e.isFavorites), isEmpty);

      final sub = groups.first.forumList.first;
      expect(sub.name, 'GLTEST 子版塊（型別 sub）');
      expect(sub.url, '$baseUrl/forum.php?mod=forumdisplay&fid=15');
      expect(sub.iconUrl, '$baseUrl/data/attachment/common/tsdmapp281_sub.png');
      expect((sub.threadCount, sub.replyCount), (10, 10));
      expect(sub.latestThreadUrl, '$baseUrl/forum.php?mod=redirect&tid=9199857&goto=lastpost');
      expect(sub.latestThreadTitle, '1.9.0 子版发帖 758113');
      expect(sub.latestThreadUserName, 'ag_low2');
      expect(sub.latestThreadTime, DateTime.fromMillisecondsSinceEpoch(1792256772 * 1000));
      expect(sub.isPrivate, isFalse);
      expect(sub.redirectUrl, isNull);
      // The forum lists no subforums here: the subforum is nowhere among the categories.
      expect(groups.skip(1).expand((e) => e.forumList).map((e) => e.forumID), isNot(contains(15)));

      // The group's forum, listed in no category either.
      final groupForum = groups.first.forumList.last;
      expect(groupForum.name, 'BU群組855956');
      expect((groupForum.threadCount, groupForum.replyCount), (3, 3));
      expect(groupForum.latestThreadUserName, 'ag_mid');
    });

    test('a forum with subforums: its own counts, where the categories (and the panel before) add the subforums', () {
      final json = _plugin281();
      final parent = _panel(json)[1];
      expect(parent.forumID, 2);
      expect((parent.threadCount, parent.replyCount), (47, 147));
      final listed = _inCategories(json, 2);
      expect((listed.threadCount, listed.replyCount), (57, 157), reason: 'with the 10 / 10 of subforum 15');

      // What the panel showed when it looked the favorites up among the categories (the answer of plugin 2.8.0,
      // lean): the categories' counts, the subforum, the hidden forum and the group's forum left out.
      final before = _panel(_older(json));
      expect(before.map((e) => e.forumID), [2, 7, 29]);
      expect((before.first.threadCount, before.first.replyCount), (57, 157));

      // The member of the index fixture: the same forum, the same counts.
      final member = _json('tsdmapp/index_v5_member.json');
      expect(_panel(member).map((e) => (e.forumID, e.threadCount, e.replyCount)), [(2, 47, 147)]);
      expect(_inCategories(member, 2).threadCount, 57);
    });

    test('a link forum: its address, no counts, no latest thread', () {
      final link = _panel(_plugin281())[4];
      expect(link.forumID, 29);
      expect(link.redirectUrl, 'https://example.com/tsdmapp281');
      expect((link.threadCount, link.replyCount, link.threadTodayCount), (0, 0, null));
      expect(link.latestThreadUrl, isNull);
      expect(link.latestThreadTime, isNull);
      expect(link.isPrivate, isFalse);
    });

    test('a forum hidden from the viewer (hideprivate): no icon, no latest thread, the counts; not marked', () {
      final hidden = _panel(_plugin281())[2];
      expect(hidden.forumID, 26);
      expect(hidden.name, 'BU 黑名單權限版 G');
      expect(hidden.iconUrl, isEmpty, reason: 'the page prints the file name of the icon as text');
      expect((hidden.threadCount, hidden.replyCount), (10, 10));
      expect(hidden.latestThreadUrl, isNull);
      expect(hidden.latestThreadTime, isNull);
      expect(hidden.isPrivate, isFalse, reason: 'the page prints no 私密版块 then');
      expect(hidden.redirectUrl, isNull);
    });

    test('private 1 (a forum that does not hide them): marked, its counts and icon kept', () {
      final json = _plugin281();
      final favorites = (json['favorites'] as List).cast<Map<String, dynamic>>();
      favorites[3] = {...favorites[3], 'private': 1, 'lastpost': null, 'icon': '$baseUrl/data/attachment/common/7.png'};
      final forum = _panel(json)[3];
      expect(forum.forumID, 7);
      expect(forum.isPrivate, isTrue);
      expect((forum.threadCount, forum.replyCount), (27, 2300));
      expect(forum.iconUrl, '$baseUrl/data/attachment/common/7.png');
      expect(forum.latestThreadTime, isNull);
      expect(_panel(_plugin281())[3].isPrivate, isFalse);
    });

    test("the panel follows the favorites' order; every id of favorite_forums is seeded as before", () {
      final json = _plugin281();
      json['favorites'] = (json['favorites'] as List).reversed.toList();
      expect(_panel(json).map((e) => e.forumID), [28, 29, 7, 26, 2, 15]);
      expect(favoriteForumIdsOf(json), [15, 2, 26, 7, 29, 28]);
    });

    test('no panel: a guest, a member without favorites, the categories untouched', () {
      final guest = _json('tsdmapp/index_v5_guest.json');
      expect(guest['favorites'], isEmpty);
      expect(forumGroupsFromApi(guest).where((e) => e.isFavorites), isEmpty);
      final none = {..._plugin281(), 'favorites': <Object?>[], 'favorite_forums': <Object?>[]};
      expect(forumGroupsFromApi(none).where((e) => e.isFavorites), isEmpty);
      expect(
        forumGroupsFromApi(none).map((e) => e.name),
        forumGroupsFromApi(_plugin281()).skip(1).map((e) => e.name),
      );
    });
  });

  group('plugin 2.3.0 to 2.8.0: the panel read from the page', () {
    test('favoritesPanelNeedsDocument: favorites named by id only, lean; nothing else', () {
      final older = _older(_plugin281());
      expect(favoritesPanelNeedsDocument(older), isTrue);
      expect(favoritesPanelNeedsDocument(_plugin281()), isFalse, reason: 'plugin 2.8.1');
      expect(favoritesPanelNeedsDocument({..._plugin281(), 'favorites': <Object?>[]}), isFalse);
      expect(favoritesPanelNeedsDocument(_older(_withDocument())), isFalse, reason: 'the document is there');
      expect(favoritesPanelNeedsDocument({...older, 'favorite_forums': <Object?>[]}), isFalse, reason: 'no favorites');
      expect(favoritesPanelNeedsDocument(_older(_json('tsdmapp/index_v5_guest.json'))), isFalse, reason: 'a guest');
      expect(
        favoritesPanelNeedsDocument({'ok': 0, 'error': 'message', 'message': '站点已关闭', 'login': 0, 'schema': 5}),
        isFalse,
        reason: "the forum's message",
      );
    });

    test('the panel of the page gives what the plugin gives for the same moment', () {
      final full = _withDocument();
      final fromApi = _panel(full);
      final fromPage = _panel(_older(full));
      expect(fromPage.map((e) => e.forumID), [15, 2, 26, 7, 29, 28]);
      expect(fromPage.map((e) => e.forumID), fromApi.map((e) => e.forumID));
      for (final (page, api) in IterableZip([fromPage, fromApi]).map((e) => (e[0], e[1]))) {
        final reason = 'fid ${api.forumID}';
        expect(page.name, api.name, reason: reason);
        expect((page.threadCount, page.replyCount), (api.threadCount, api.replyCount), reason: reason);
        expect(page.threadTodayCount, api.threadTodayCount, reason: reason);
        expect(page.isPrivate, api.isPrivate, reason: reason);
        expect(page.redirectUrl == null, api.redirectUrl == null, reason: reason);
        expect(
          page.latestThreadUrl?.uriQueryParameter('tid'),
          api.latestThreadUrl?.uriQueryParameter('tid'),
          reason: reason,
        );
        expect(page.latestThreadTime == null, api.latestThreadTime == null, reason: reason);
        if (api.latestThreadTime != null) {
          expect(_pageMinute(page.latestThreadTime!), _wallMinute(api.latestThreadTime!), reason: reason);
        }
      }
      // The parent forum: its own counts, not the categories'.
      expect((fromPage[1].threadCount, fromPage[1].replyCount), (47, 147));
      expect(_inCategories(full, 2).threadCount, 57);

      // What only the page has: the forum's default picture for a forum without an icon, the icon as the page links
      // it; nothing for the hidden forum (its file name printed as text). The grid prints no title nor author of the
      // latest thread, and no address of the link forum: its own page, which the forum redirects.
      expect(fromPage.map((e) => e.iconUrl), [
        'data/attachment/common/tsdmapp281_sub.png',
        'template/discuzx5/static//images/forum.png',
        '',
        'template/discuzx5/static//images/forum.png',
        'template/discuzx5/static//images/forum.png',
        'template/discuzx5/static//images/forum.png',
      ]);
      expect(fromPage.map((e) => e.latestThreadTitle), everyElement(isNull));
      expect(fromPage[4].redirectUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=29');
      expect(fromApi[4].redirectUrl, 'https://example.com/tsdmapp281');
    });

    test('the list layout of up to three: a forum the viewer may not enter, a link forum; the web path as before', () {
      final document = parseHtmlDocument(_listLayoutPage);
      final forums = favoriteForumsOfDocument(document)!;
      expect(forums.map((e) => e.forumID), [7, 26, 29]);

      final normal = forums[0];
      expect((normal.threadCount, normal.replyCount, normal.threadTodayCount), (27, 12300, 3));
      expect(normal.iconUrl, 'data/attachment/common/7.png');
      expect(normal.latestThreadTitle, 'ATP JSON 89328');
      expect(normal.latestThreadUserName, 'ag_low2');
      expect(_pageMinute(normal.latestThreadTime!), (2026, 9, 23, 21, 58));
      expect((normal.isPrivate, normal.redirectUrl), (false, null));

      final private = forums[1];
      expect(private.isPrivate, isTrue);
      expect((private.threadCount, private.replyCount), (10, 10));
      expect(private.iconUrl, 'data/attachment/common/26.png');
      expect(private.latestThreadUrl, isNull);
      expect(private.latestThreadTime, isNull);

      final link = forums[2];
      expect(link.name, 'BU 通知驗收版 H');
      expect((link.threadCount, link.replyCount, link.threadTodayCount), (0, 0, null));
      expect(link.redirectUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=29');
      expect(link.iconUrl, 'template/discuzx5/static//images/forum.png');
      expect(link.latestThreadUrl, isNull);

      // The reader of the web page (no plugin, or one before 2.3.0) is untouched: it still drops the link forum.
      final web = buildGroupListFromDocument(document).single;
      expect(web.isFavorites, isTrue);
      expect(web.forumList.map((e) => e.forumID), [7, 26]);
      expect(web.forumList.map((e) => e.isPrivate), [false, false]);
    });

    test('the production page: the same forums as the reader of the web page', () {
      final document = parseHtmlDocument(File('test/data/forum_index_x5.html').readAsStringSync());
      final web = buildGroupListFromDocument(document).firstWhere((e) => e.isFavorites).forumList;
      final forums = favoriteForumsOfDocument(document)!;
      expect(forums, web);
      expect(forums.single.forumID, 125);
      expect(
        favoriteForumsOfDocument(parseHtmlDocument(File('test/data/forum_index_nofav_x5.html').readAsStringSync())),
        isNull,
      );
    });

    test('without the document, or a document without the panel: looked up among the categories as before', () {
      final lean = _lean(_older(_withDocument()));
      expect(_panel(lean).map((e) => e.forumID), [2, 7, 29]);
      final garbage = {...lean, 'document': '<div id="wp">nothing</div>'};
      expect(_panel(garbage).map((e) => e.forumID), [2, 7, 29]);
      expect(_panel({...lean, 'favorite_forums': <Object?>[]}), isEmpty);
    });
  });

  group('the repository: one request more, only for an older plugin naming favorites', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late CookieProvider cookie;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      cookie = CookieProvider(_viewer, {});
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(cookie);
      await settings.init();
    });
    tearDown(() async {
      if (getIt.isRegistered<NetClientProvider>()) {
        await getIt.unregister<NetClientProvider>();
      }
      await settings.dispose();
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await getIt.unregister<CookieProvider>();
      await db.close();
    });

    ForumHomeRepository repositoryOf(_Forum forum) {
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
      final repo = ForumHomeRepository();
      addTearDown(repo.dispose);
      return repo;
    }

    test('plugin 2.8.0 with favorites: asked again without nodoc, that answer is the page, published once', () async {
      final forum = _Forum(
        lean: () => _api(_lean(_older(_withDocument()))),
        full: () => _api(_older(_withDocument())),
      );
      final repo = repositoryOf(forum);
      final published = <ForumHomePage>[];
      final sub = repo.pageStream.listen(published.add);
      addTearDown(sub.cancel);

      final page = _right(await repo.fetchHomePage().run());
      expect(forum.homepage, hasLength(2));
      expect(forum.homepage[0].uri.queryParameters, containsPair('nodoc', '1'));
      expect(forum.homepage[1].uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(forum.homepage[1].uri.queryParameters, isNot(contains('nodoc')), reason: 'the answer keeps its document');
      expect(forum.homepage[1].uri.queryParameters.keys.toSet(), {'tsdmapp', 'mobile'});
      expect(page, isA<ForumHomeApiPage>());
      final json = (page as ForumHomeApiPage).json;
      expect(json['document'], isA<String>());
      expect(page.servedUid, 35);
      expect(_panel(json).map((e) => (e.forumID, e.threadCount)), [
        (15, 10),
        (2, 47),
        (26, 10),
        (7, 27),
        (29, 0),
        (28, 3),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(published, [page], reason: 'one page for the homepage and the topics tab');
      expect(repo.getCache(), same(page));

      // The cache answers again; a forced fetch costs the two requests again.
      expect(_right(await repo.fetchTopicPage().run()), same(page));
      expect(forum.homepage, hasLength(2));
      await repo.fetchTopicPage(force: true).run();
      expect(forum.homepage, hasLength(4));
    });

    test('no request more: plugin 2.8.1, a member without favorites, a guest, the forum message', () async {
      for (final (name, answer) in [
        ('2.8.1', _plugin281()),
        ('no favorites', {..._older(_plugin281()), 'favorite_forums': <Object?>[]}),
        ('guest', _older(_json('tsdmapp/index_v5_guest.json'))),
        ('message', {'ok': 0, 'error': 'message', 'message': '站点已关闭', 'login': 0, 'schema': 5}),
      ]) {
        final forum = _Forum(lean: () => _api(answer));
        final repo = repositoryOf(forum);
        await repo.fetchHomePage().run();
        expect(forum.homepage, hasLength(1), reason: name);
        expect(forum.homepage.single.uri.queryParameters, containsPair('nodoc', '1'), reason: name);
        await getIt.unregister<NetClientProvider>();
      }
    });

    test('the answer with its document failed or is another account: the lean page stays, as before', () async {
      for (final (name, full) in [
        ('failed', _api({'ok': 0, 'error': 'internal'})),
        ('HTTP 500', _api('', status: 500)),
        ('another account', _api({..._older(_withDocument()), 'uid': 36})),
        ('a guest', _api({..._older(_withDocument()), 'uid': 0})),
      ]) {
        final forum = _Forum(lean: () => _api(_lean(_older(_withDocument()))), full: () => full);
        final repo = repositoryOf(forum);
        final page = _right(await repo.fetchHomePage().run());
        expect(forum.homepage, hasLength(2), reason: name);
        final json = (page as ForumHomeApiPage).json;
        expect(json.containsKey('document'), isFalse, reason: name);
        expect(page.servedUid, 35, reason: name);
        expect(_panel(json).map((e) => e.forumID), [2, 7, 29], reason: '$name: looked up among the categories');
        await getIt.unregister<NetClientProvider>();
      }
    });

    test('the account changes while the page with its document is asked: dropped, nothing kept', () async {
      final forum = _Forum(
        lean: () => _api(_lean(_older(_withDocument()))),
        full: () => _api(_older(_withDocument())),
        onFull: cookie.clearUserInfoAndCookie,
      );
      final repo = repositoryOf(forum);
      final result = await repo.fetchHomePage().run();
      expect(result.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(forum.homepage, hasLength(2));
      expect(repo.hasCache(), isFalse);
    });
  });

  group('the topics tab and the homepage share the fetch', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late _Forum forum;
    late ForumHomeRepository forumHome;
    late FavoriteRepository favorites;
    late _FakeAuth auth;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      forum = _Forum(
        lean: () => _api(_lean(_older(_withDocument()))),
        full: () => _api(_older(_withDocument())),
      );
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        );
      await settings.init();
      forumHome = ForumHomeRepository();
      favorites = FavoriteRepository();
      auth = _FakeAuth(_viewer);
    });
    tearDown(() async {
      await forumHome.dispose();
      await favorites.dispose();
      await auth.dispose();
      await settings.dispose();
      await getIt.unregister<NetClientProvider>();
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await getIt.unregister<CookieProvider>();
      await db.close();
    });

    TopicsBloc topicsBloc() {
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
      );
      addTearDown(bloc.close);
      return bloc;
    }

    test('plugin 2.8.0: the panel of the page, every favorite seeded; the homepage reuses the page', () async {
      final bloc = topicsBloc()..add(TopicsLoadRequested());
      final loaded = await bloc.stream.firstWhere((s) => s.status.isSuccess);
      expect(loaded.forumGroupList.first.isFavorites, isTrue);
      expect(loaded.forumGroupList.first.forumList.map((e) => e.forumID), [15, 2, 26, 7, 29, 28]);
      expect(loaded.forumGroupList.first.forumList[1].threadCount, 47);
      expect(forum.homepage, hasLength(2));
      for (final fid in [15, 2, 26, 7, 29, 28]) {
        expect(favorites.isForumFavorited(uid: 35, fid: '$fid'), isTrue, reason: 'seeded: $fid');
      }

      // The homepage starts from the same page: nothing asked.
      final homepage = HomepageBloc(
        forumHomeRepository: forumHome,
        profileRepository: ProfileRepository(),
        authenticationRepository: auth,
      );
      addTearDown(homepage.close);
      expect(homepage.state.status, HomepageStatus.success);
      expect(forum.homepage, hasLength(2));

      // The homepage refreshes it: the topics tab takes the published page, asking nothing itself.
      await forumHome.fetchHomePage(force: true).run();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forum.homepage, hasLength(4));
      expect(bloc.state.forumGroupList.first.forumList, hasLength(6));
    });

    test('plugin 2.8.1: one request, the panel of the answer, every favorite seeded', () async {
      forum.lean = () => _api(_plugin281());
      final bloc = topicsBloc()..add(TopicsLoadRequested());
      final loaded = await bloc.stream.firstWhere((s) => s.status.isSuccess);
      expect(loaded.forumGroupList.first.forumList.map((e) => e.forumID), [15, 2, 26, 7, 29, 28]);
      expect(forum.homepage, hasLength(1));
      for (final fid in [15, 2, 26, 7, 29, 28]) {
        expect(favorites.isForumFavorited(uid: 35, fid: '$fid'), isTrue, reason: 'seeded: $fid');
      }
    });
  });

  group('the cards of the panel', () {
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <MethodCall>[];
    late AppDatabase db;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _Forum(lean: () => _api('')),
          ),
        );
      await settings.init();
      getIt.registerSingleton<ImageCacheProvider>(ImageCacheProvider(getIt.get<NetClientProvider>()));
      launched.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (
        call,
      ) async {
        launched.add(call);
        return true;
      });
    });
    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, null);
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.unregister<ImageCacheProvider>();
      await getIt.unregister<NetClientProvider>();
      await settings.dispose();
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await getIt.unregister<CookieProvider>();
      await db.close();
    });

    Future<GoRouter> pumpCards(WidgetTester tester, List<Forum> forums, {bool large = false}) async {
      tester.view
        ..physicalSize = large ? const Size(1400, 2400) : const Size(390, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              // No picture to load in a widget test.
              body: ListView(
                children: [for (final f in forums) ForumCard(f.copyWith(iconUrl: ''), large: large)],
              ),
            ),
          ),
          GoRoute(
            path: ScreenPaths.forum,
            name: ScreenPaths.forum,
            builder: (_, state) => Text('forum ${state.pathParameters['fid']}'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return router;
    }

    Finder card(int fid) => find.byWidgetPredicate((w) => w is ForumCard && w.forum.forumID == fid);
    Finder inCard(int fid, Finder finder) => find.descendant(of: card(fid), matching: finder);

    testWidgets('private: 私密版块 where the time goes, the counters kept; a link forum: no counters', (tester) async {
      final json = _plugin281();
      final favorites = (json['favorites'] as List).cast<Map<String, dynamic>>();
      favorites[3] = {...favorites[3], 'private': 1, 'lastpost': null};
      final forums = _panel(json);
      for (final large in [false, true]) {
        await pumpCards(tester, forums, large: large);
        expect(inCard(7, find.text(tr.forumCard.privateForum)), findsOneWidget, reason: 'large: $large');
        expect(inCard(7, find.text('27')), findsOneWidget, reason: 'large: $large');
        expect(inCard(29, find.text(tr.forumCard.redirectForum)), findsOneWidget, reason: 'large: $large');
        expect(inCard(29, find.byType(large ? ForumCardStat : AppInfoPill)), findsNothing, reason: 'large: $large');
        expect(inCard(15, find.byType(large ? ForumCardStat : AppInfoPill)), findsNWidgets(3), reason: 'large: $large');
        expect(inCard(15, find.text(tr.forumCard.privateForum)), findsNothing);
        expect(inCard(26, find.text(tr.forumCard.privateForum)), findsNothing, reason: 'hidden, not private');
      }
      expect(tr.forumCard.privateForum, '私密版块');
      expect(tr.forumCard.redirectForum, '链接到外部地址');
    });

    testWidgets('tapping a link forum opens its address in the browser; another forum opens its page', (tester) async {
      final router = await pumpCards(tester, _panel(_plugin281()));
      await tester.tap(card(29));
      await tester.pump(const Duration(milliseconds: 100));
      expect(launched.map((e) => (e.arguments as Map)['url']), ['https://example.com/tsdmapp281']);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');

      await tester.tap(card(15));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('forum 15'), findsOneWidget);
      expect(launched, hasLength(1));
    });
  });

  test('the app expects plugin 2.8.1; 2.8.0 is older (no favorites panel)', () {
    expect(expectedTsdmAppVersion, '2.8.1');
    expect(const TsdmAppPluginInfo(version: '2.8.0', api: 1, nodoc: true).olderThanExpected, isTrue);
    expect(const TsdmAppPluginInfo(version: '2.8.1', api: 1, nodoc: true).olderThanExpected, isFalse);
  });
}
