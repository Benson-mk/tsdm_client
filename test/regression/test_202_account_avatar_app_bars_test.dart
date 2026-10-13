import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/view/forum_group_page.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/multi_user/cubit/current_account_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/topics/view/topics_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
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
import 'package:tsdm_client/widgets/list_app_bar/list_app_bar.dart';

/// GitHub #184: users with several accounts sometimes posted with the wrong one because only the homepage showed the
/// account in use. The app bars of the pages one browses and posts from (forum, thread, the forums tab and a forum
/// group) now show its avatar, but only when more than one account is saved.

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

final Finder _button = find.byKey(const ValueKey('current_account_avatar_button'));

/// Every request fails at once: no page content is needed, only the app bars.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Notification bloc that stays in its initial state.
final class _Notifications extends Fake implements NotificationBloc {
  final _controller = StreamController<NotificationState>.broadcast(sync: true);

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => _controller.stream;

  @override
  void add(NotificationEvent event) {}

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => _controller.close();
}

/// A few frames with real time in between, for the database and the failing network.
Future<void> _settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late AuthenticationRepository auth;
  late NotificationInfoRepository info;
  late NotificationStateCubit counts;
  late _Notifications notifications;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _OfflineAdapter()),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    auth = AuthenticationRepository(user: _alice);
    info = NotificationInfoRepository();
    counts = NotificationStateCubit(info);
    notifications = _Notifications();
  });

  tearDown(() async {
    await notifications.close();
    await counts.close();
    await info.dispose();
    await auth.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// A [CurrentAccountCubit] with Alice logged in and [accounts] saved.
  Future<CurrentAccountCubit> accountCubit(WidgetTester tester, List<UserLoginInfo> accounts) async {
    final saved = StreamController<List<UserLoginInfo>>();
    final cubit = CurrentAccountCubit(
      currentUser: () => _alice,
      authStatus: const Stream.empty(),
      accounts: saved.stream,
    );
    saved.add(accounts);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    addTearDown(() async {
      await cubit.close();
      await saved.close();
    });
    return cubit;
  }

  /// [home] under the providers of the app, with [cubit] provided when not null.
  Future<void> pumpHost(WidgetTester tester, Widget home, CurrentAccountCubit? cubit) async {
    final forumHome = ForumHomeRepository();
    final favorites = FavoriteRepository();
    final jump = JumpPageCubit()
      ..setPageInfo(currentPage: 123, totalPages: 456)
      ..markSuccess();
    addTearDown(() async {
      await jump.close();
      await favorites.dispose();
      await forumHome.dispose();
    });
    Widget app = MaterialApp(home: home);
    if (cubit != null) {
      app = BlocProvider<CurrentAccountCubit>.value(value: cubit, child: app);
    }
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
            RepositoryProvider<FavoriteRepository>.value(value: favorites),
            RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
            RepositoryProvider<ForumRepository>(create: (_) => ForumRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<NotificationBloc>.value(value: notifications),
              BlocProvider<NotificationStateCubit>.value(value: counts),
              BlocProvider<JumpPageCubit>.value(value: jump),
            ],
            child: app,
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  /// The app bar of the forum and thread pages, with a long title, the jump page pill and a bottom row.
  Widget listPage() => Scaffold(
    appBar: ListAppBar(
      title: 'A rather long thread title that has to give way to the actions',
      bottom: const PreferredSize(preferredSize: Size.fromHeight(40), child: SizedBox(height: 40)),
      showReverseOrderAction: true,
      onJumpPage: (_) {},
      onRefresh: () {},
      onCopyUrl: () {},
      onOpenInBrowser: () {},
    ),
    body: const SizedBox.shrink(),
  );

  final pages = <String, Widget Function()>{
    'list app bar (forum, thread)': listPage,
    'topics page': () => const TopicsPage(),
    'forum group page': () => const ForumGroupPage(gid: '1', title: 'Group'),
  };

  // GitHub #184 feedback: on the topics page the avatar sat a little further right than on the homepage, which leaves
  // 4px after its avatar.
  for (final MapEntry(key: name, value: page) in {
    'topics page': () => const TopicsPage(),
    'forum group page': () => const ForumGroupPage(gid: '1', title: 'Group'),
  }.entries) {
    testWidgets('$name: the avatar sits where the homepage avatar sits', (tester) async {
      final cubit = await accountCubit(tester, [_alice, _bob]);
      await pumpHost(tester, page(), cubit);
      final shown = tester.getRect(find.byKey(const ValueKey('current_account_avatar_button')));

      // The end of the homepage app bar: the avatar button, then a 4px gap.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                IconButton(key: const ValueKey('home'), icon: const SizedBox(width: 32, height: 32), onPressed: () {}),
                const SizedBox(width: 4, height: 4),
              ],
            ),
          ),
        ),
      );
      expect(shown.right, tester.getRect(find.byKey(const ValueKey('home'))).right);
      expect(shown.width, tester.getRect(find.byKey(const ValueKey('home'))).width);
      await _settle(tester);
    });
  }

  for (final MapEntry(key: name, value: page) in pages.entries) {
    group(name, () {
      testWidgets('shows the account with two saved accounts', (tester) async {
        await pumpHost(tester, page(), await accountCubit(tester, [_alice, _bob]));
        expect(_button, findsOneWidget);
        expect(
          find.descendant(of: find.byType(AppBar), matching: _button),
          findsOneWidget,
          reason: 'the button sits in the app bar',
        );
        final tooltip = tester.widget<IconButton>(_button).tooltip;
        expect(tooltip, contains('Alice'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('shows nothing with a single saved account', (tester) async {
        await pumpHost(tester, page(), await accountCubit(tester, [_alice]));
        expect(_button, findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('shows nothing without the cubit', (tester) async {
        await pumpHost(tester, page(), null);
        expect(_button, findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }

  group('list app bar', () {
    testWidgets('the button comes first, before the notice button', (tester) async {
      await pumpHost(tester, listPage(), await accountCubit(tester, [_alice, _bob]));
      final actions = tester.widget<AppBar>(find.byType(AppBar)).actions!;
      expect(actions.first.runtimeType.toString(), 'CurrentAccountAvatarButton');
      expect(actions[1].runtimeType.toString(), 'NoticeButton');
    });

    /// Opens the list page on a [width] wide window with [scale] text, Alice and [accounts] saved.
    Future<void> pumpPhone(WidgetTester tester, double width, double scale, List<UserLoginInfo> accounts) async {
      tester.view
        ..physicalSize = Size(width, 640)
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      // Pushed, so the app bar also has a back button, like the forum and thread pages.
      await pumpHost(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => listPage())),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        await accountCubit(tester, accounts),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('123'), findsOneWidget);
    }

    for (final scale in [1.0, 1.3]) {
      testWidgets('fits a 320px wide phone with $scale text and the page pill', (tester) async {
        await pumpPhone(tester, 320, scale, [_alice, _bob]);
        expect(_button, findsOneWidget);
        // A RenderFlex overflow is reported as an exception.
        expect(tester.takeException(), isNull);
        // The pill left out the total pages to make room for the account.
        expect(find.text(' / 456'), findsNothing);
        // Every action stays on screen, the menu included.
        for (final finder in [_button, find.byIcon(Icons.notifications_outlined), find.byIcon(Icons.more_vert)]) {
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$finder starts on screen');
          expect(rect.right, lessThanOrEqualTo(320), reason: '$finder ends on screen');
        }
      });
    }

    testWidgets('keeps the total pages with a single account', (tester) async {
      await pumpPhone(tester, 320, 1, [_alice]);
      expect(_button, findsNothing);
      expect(find.text(' / 456'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the total pages on a wider phone', (tester) async {
      await pumpPhone(tester, 412, 1, [_alice, _bob]);
      expect(_button, findsOneWidget);
      expect(find.text(' / 456'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
