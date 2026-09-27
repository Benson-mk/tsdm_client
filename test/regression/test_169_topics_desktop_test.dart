import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/topics/view/topics_page.dart';
import 'package:tsdm_client/features/topics/widgets/group_moderators_row.dart';
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
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

/// preview106 feedback: on a desktop window the topics page used the shared 960px list width, so four small forum
/// cards sat in the middle of a wide window. The page now widens to [topicsPageMaxWidth] (still two columns) and shows
/// large cards once it really has [topicsPageLargeCardWidth]; phones and medium windows keep the compact layout.
///
/// Fake data only (same fake index shape as test_043): no forum icon, so no image is fetched.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// Serves the fake forum index for every `/forum.php` request.
final class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.index);

  final String Function() index;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
    }
    if (options.uri.path != '/forum.php') {
      return ResponseBody.fromString('not found', 404);
    }
    return ResponseBody.fromString(
      index(),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _FakeAuth extends AuthenticationRepository {
  final subject = BehaviorSubject<AuthStatus>();

  @override
  UserLoginInfo? get currentUser => _alice;

  @override
  Stream<AuthStatus> get status => subject.stream;

  @override
  Future<void> dispose() async {
    await subject.close();
    await super.dispose();
  }
}

String _forumRow(int fid, String name) =>
    '<tr class="fl_row"><td class="fl_icn"></td> '
    '<td><h2><a href="forum.php?mod=forumdisplay&amp;fid=$fid">$name</a></h2></td> '
    '<td class="fl_i"><span class="xi2"><span title="228862">228862</span></span> '
    '<span class="xg1"> / <span title="10967904">10967904</span></span></td></tr>';

/// One group with [moderators] in its header and [forums] as fid 1000, 1001...
String _index(List<String> forums, {List<String> moderators = const ['琴吹紬', '捕风巫', 'cu', '未梓林']}) {
  final mods = moderators.map((e) => '<a href="home.php?mod=space&amp;username=$e">$e</a>').join(', ');
  return '<html><body><div id="hd"><div class="wp"><div class="hdc cl"><div id="um"> '
      '<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p> '
      '</div></div></div></div><div id="ct"><div class="mn"><div class="fl bm">'
      '<div class="bm bmw  cl"><div class="bm_h cl"><span class="y">分区版主: $mods</span>'
      '<h2><a href="forum.php?gid=1">天使·后花园</a></h2></div> '
      '<div id="category_1" class="bm_c"><table class="fl_tb">'
      '${forums.indexed.map((f) => _forumRow(1000 + f.$1, f.$2)).join()}'
      '<tr class="fl_row"></tr></table></div></div>'
      '</div></div></div></body></html>';
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late AppDatabase db;
  late SettingsRepository settings;
  late ForumHomeRepository forumHome;
  late FavoriteRepository favorites;
  late _FakeAuth auth;
  late FragmentsRepository fragments;
  var forums = <String>['新人报到', '活动专区', '若闲小阁', '天使名册'];

  setUp(() async {
    forums = ['新人报到', '活动专区', '若闲小阁', '天使名册'];
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    final adapter = _FakeAdapter(() => _index(forums));
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
    await settings.init();
    getIt.registerSingleton<ImageCacheProvider>(ImageCacheProvider(getIt.get<NetClientProvider>()));
    forumHome = ForumHomeRepository();
    favorites = FavoriteRepository();
    auth = _FakeAuth();
    fragments = FragmentsRepository();
  });
  tearDown(() async {
    await forumHome.dispose();
    await favorites.dispose();
    await auth.dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// `pumpAndSettle` never returns here because a refresh indicator keeps animating.
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  GoRouter router() => GoRouter(
    initialLocation: ScreenPaths.topic,
    routes: [
      GoRoute(path: ScreenPaths.topic, name: ScreenPaths.topic, builder: (_, _) => const TopicsPage()),
      GoRoute(
        path: ScreenPaths.forum,
        name: ScreenPaths.forum,
        builder: (_, state) => Text('forum ${state.pathParameters['fid']}'),
      ),
      GoRoute(
        path: ScreenPaths.profile,
        name: ScreenPaths.profile,
        builder: (_, state) => Text('profile ${state.uri.queryParameters['username']}'),
      ),
    ],
  );

  Future<GoRouter> pumpTopics(WidgetTester tester, Size size, {double textScale = 1}) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (textScale != 1) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    final r = router();
    addTearDown(r.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<FavoriteRepository>.value(value: favorites),
            RepositoryProvider<FragmentsRepository>.value(value: fragments),
          ],
          child: MaterialApp.router(routerConfig: r),
        ),
      ),
    );
    await pumpFrames(tester);
    return r;
  }

  Finder card(int index) => find.byType(ForumCard).at(index);
  Size imageSize(WidgetTester tester, int index) =>
      tester.getSize(find.descendant(of: card(index), matching: find.byType(NetworkIndicatorImage)));

  testWidgets('desktop: wider content, two columns of large cards aligned with the moderators row', (tester) async {
    await pumpTopics(tester, const Size(1600, 1000));
    expect(tester.takeException(), isNull);
    expect(find.byType(ForumCard), findsNWidgets(4));
    expect(tester.widgetList<ForumCard>(find.byType(ForumCard)).every((e) => e.large), isTrue);

    // Content spans topicsPageMaxWidth (1320) centered in 1600, not the shared 960.
    const side = (1600 - topicsPageMaxWidth) / 2;
    final first = tester.getRect(card(0));
    final second = tester.getRect(card(1));
    expect(first.left, moreOrLessEquals(side));
    expect(second.right, moreOrLessEquals(1600 - side));
    expect(second.right - first.left, greaterThan(appListMaxWidth + 200));

    // Still two columns (no grid of many small cards), each card much wider than before (~474).
    expect(second.top, moreOrLessEquals(first.top));
    expect(tester.getRect(card(2)).top, greaterThan(first.bottom));
    expect(first.width, moreOrLessEquals((topicsPageMaxWidth - appSurfaceGap) / 2));

    // The moderators row has the same edges as the cards.
    final mods = tester.getRect(find.byType(GroupModeratorsRow));
    expect(mods.left, moreOrLessEquals(first.left));
    expect(mods.right, moreOrLessEquals(second.right));
    expect(tester.widget<GroupModeratorsRow>(find.byType(GroupModeratorsRow)).large, isTrue);

    // Bigger content, not only a wider card: picture, name, counters.
    expect(imageSize(tester, 0), forumCardLargeImageSize);
    expect(forumCardLargeImageSize.width, inInclusiveRange(120, 140));
    expect(tester.widget<Text>(find.text('新人报到')).style?.fontSize, 20);
    final pills = tester.widgetList<AppInfoPill>(find.descendant(of: card(0), matching: find.byType(AppInfoPill)));
    expect(pills, hasLength(3));
    expect(pills.every((e) => e.large), isTrue);
  });

  testWidgets('a medium window keeps the compact cards and the shared width', (tester) async {
    await pumpTopics(tester, const Size(1000, 800));
    expect(tester.takeException(), isNull);
    expect(tester.widgetList<ForumCard>(find.byType(ForumCard)).any((e) => e.large), isFalse);
    final first = tester.getRect(card(0));
    final second = tester.getRect(card(1));
    expect(second.right - first.left, moreOrLessEquals(appListMaxWidth));
    expect(second.top, moreOrLessEquals(first.top), reason: 'two columns from appTwoColumnWidth, as before');
    expect(imageSize(tester, 0), forumCardImageSize);
    expect(tester.widget<Text>(find.text('新人报到')).style?.fontSize, isNot(20));
    expect(tester.widget<GroupModeratorsRow>(find.byType(GroupModeratorsRow)).large, isFalse);
  });

  testWidgets('phone 320 at 2x text with long names: one compact column, no overflow while scrolling', (tester) async {
    forums = [for (var i = 0; i < 6; i++) '很长很长的版块名称$i' * 4];
    await pumpTopics(tester, const Size(320, 640), textScale: 2);
    expect(tester.takeException(), isNull);
    expect(tester.widgetList<ForumCard>(find.byType(ForumCard)).any((e) => e.large), isFalse);
    // One column on phones: the card fills the page minus the phone side padding (12 each side).
    expect(tester.getRect(card(0)).width, moreOrLessEquals(320 - 2 * appPagePadding(320)));
    final list = find.descendant(of: find.byType(TabBarView), matching: find.byType(ListView)).first;
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('narrowest large layout at 2x text with long names does not overflow', (tester) async {
    forums = [for (var i = 0; i < 6; i++) '很长很长的版块名称$i' * 6];
    await pumpTopics(tester, const Size(topicsPageLargeCardWidth, 700), textScale: 2);
    expect(tester.takeException(), isNull);
    expect(tester.widgetList<ForumCard>(find.byType(ForumCard)).every((e) => e.large), isTrue);
    expect(tester.getRect(card(1)).top, moreOrLessEquals(tester.getRect(card(0)).top));
    expect(imageSize(tester, 0), forumCardLargeImageSize);
    final list = find.descendant(of: find.byType(TabBarView), matching: find.byType(ListView)).first;
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('large cards and moderator chips still navigate', (tester) async {
    final r = await pumpTopics(tester, const Size(1600, 1000));
    await tester.tap(find.text('活动专区'));
    await pumpFrames(tester);
    expect(find.text('forum 1001'), findsOneWidget);

    r.pop();
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(ActionChip, '捕风巫'));
    await pumpFrames(tester);
    expect(find.text('profile 捕风巫'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
