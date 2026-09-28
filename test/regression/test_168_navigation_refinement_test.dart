import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/widgets/daily_red_packet_button.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Navigation refinement of 2026-09-27:
///
/// * the side navigation (drawer on large windows, rail on medium ones) has nine real entries in two groups; the tabs
///   keep their shell state and double tap, the other entries open their page above the shell and the back button
///   returns to the selected tab; the phone bar keeps its three tabs;
/// * the notifications entry shows the real unread count by the rules of the app bar notice icon;
/// * the homepage greeting always shows a daily red packet entry with an honest state and submits at most once;
/// * the title badge of the greeting is its natural 184px on wide layouts and 160 to 184px on phones.
///
/// Synthetic accounts and answers only: no network, nothing is claimed, no login.
Translations get tr => LocaleSettings.instance.currentTranslations;

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// Pages opened above the shell by the side navigation, and the login page.
const _pushedPaths = [
  ScreenPaths.activities,
  ScreenPaths.notice,
  ScreenPaths.loggedUserProfile,
  ScreenPaths.titleShop,
  ScreenPaths.medalCenter,
  ScreenPaths.bank,
  ScreenPaths.login,
];

const _tabPaths = [ScreenPaths.homepage, ScreenPaths.topic, '/settings'];

enum _Layout { phone, tablet, desktop }

const _config = DailyRedPacketConfig(entry: 2, dateFlag: '20260927', from: 'System', bless: 'Hi', unit: 'coins');

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('side navigation', () {
    late HomeCubit cubit;
    late GoRouter router;
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 9, 27, 12);
      HomeTabDoubleTapDetector.clock = () => now;
    });

    tearDown(() => HomeTabDoubleTapDetector.clock = DateTime.now);

    String? location() => routerTopLocation(router);

    Future<void> pumpHome(
      WidgetTester tester,
      _Layout layout, {
      AuthenticationRepository? auth,
      NotificationStateCubit? notice,
    }) async {
      cubit = HomeCubit();
      router = GoRouter(
        initialLocation: ScreenPaths.homepage,
        routes: [
          ShellRoute(
            builder: (context, state, child) => switch (layout) {
              _Layout.phone => Scaffold(body: child, bottomNavigationBar: const HomeNavigationBar()),
              _Layout.tablet => Scaffold(
                body: Row(
                  children: [
                    const HomeNavigationRail(),
                    Expanded(child: child),
                  ],
                ),
              ),
              // Same constraint as HomePage puts on the drawer.
              _Layout.desktop => Scaffold(
                body: Row(
                  children: [
                    const SizedBox(width: 250, child: HomeNavigationDrawer()),
                    Expanded(child: child),
                  ],
                ),
              ),
            },
            routes: [
              for (final path in _tabPaths)
                GoRoute(
                  path: path,
                  name: path,
                  pageBuilder: (context, state) => NoTransitionPage(child: Center(child: Text('tab $path'))),
                ),
            ],
          ),
          for (final path in _pushedPaths)
            GoRoute(
              path: path,
              name: path,
              builder: (context, state) => Scaffold(
                appBar: AppBar(),
                body: Text('pushed $path'),
              ),
            ),
        ],
      );
      addTearDown(router.dispose);
      addTearDown(cubit.close);
      Widget app = BlocProvider<HomeCubit>.value(
        value: cubit,
        child: MaterialApp.router(routerConfig: router),
      );
      if (notice != null) {
        app = BlocProvider<NotificationStateCubit>.value(value: notice, child: app);
      }
      if (auth != null) {
        app = RepositoryProvider<AuthenticationRepository>.value(value: auth, child: app);
      }
      await tester.pumpWidget(TranslationProvider(child: app));
      await tester.pump();
    }

    /// Labels of the nine entries in display order.
    List<String> labels() => [
      tr.navigation.homepage,
      tr.navigation.topics,
      tr.navigation.activities,
      tr.navigation.notice,
      tr.navigation.profile,
      tr.navigation.titleShop,
      tr.navigation.medalCenter,
      tr.navigation.bank,
      tr.navigation.settings,
    ];

    int drawerSelected(WidgetTester tester) =>
        tester.widget<NavigationDrawer>(find.byType(NavigationDrawer)).selectedIndex!;

    testWidgets('drawer: nine entries in two groups, in the order of the reference', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHome(tester, _Layout.desktop);

      expect(tr.navigation.topics, 'Forums');
      final drawer = find.byType(HomeNavigationDrawer);
      var previous = double.negativeInfinity;
      for (final label in labels()) {
        final text = find.descendant(of: drawer, matching: find.text(label));
        expect(text, findsOneWidget, reason: label);
        final y = tester.getTopLeft(text).dy;
        expect(y, greaterThan(previous), reason: '$label comes after the previous entry');
        previous = y;
      }
      final header = find.descendant(of: drawer, matching: find.text(tr.navigation.moreSection));
      expect(header, findsOneWidget);
      expect(tester.getTopLeft(header).dy, greaterThan(tester.getTopLeft(find.text(tr.navigation.profile)).dy));
      expect(tester.getTopLeft(header).dy, lessThan(tester.getTopLeft(find.text(tr.navigation.titleShop)).dy));
      expect(drawerSelected(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('drawer: every page entry opens its real route, back returns to the selected tab', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = AuthenticationRepository(user: _alice);
      addTearDown(auth.dispose);
      await pumpHome(tester, _Layout.desktop, auth: auth);

      // Start on the forums tab so going back has to restore a tab other than the first one.
      await tester.tap(find.text(tr.navigation.topics));
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.topic);
      expect(drawerSelected(tester), 1);

      final pages = {
        tr.navigation.activities: ScreenPaths.activities,
        tr.navigation.notice: ScreenPaths.notice,
        tr.navigation.profile: ScreenPaths.loggedUserProfile,
        tr.navigation.titleShop: ScreenPaths.titleShop,
        tr.navigation.medalCenter: ScreenPaths.medalCenter,
        tr.navigation.bank: ScreenPaths.bank,
      };
      for (final MapEntry(key: label, value: path) in pages.entries) {
        now = now.add(const Duration(seconds: 1));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(location(), path, reason: label);
        expect(find.text('pushed $path'), findsOneWidget, reason: label);
        expect(cubit.state.tab, HomeTab.topic, reason: 'a page entry is not a tab');

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(location(), ScreenPaths.topic, reason: 'back from $label');
        expect(find.text('tab ${ScreenPaths.topic}'), findsOneWidget);
        expect(drawerSelected(tester), 1, reason: 'the forums tab stays selected after $label');
      }

      // Settings is a tab of the "more" group: selected at its own index, the tab of the cubit follows.
      now = now.add(const Duration(seconds: 1));
      await tester.tap(find.text(tr.navigation.settings));
      await tester.pumpAndSettle();
      expect(location(), '/settings');
      expect(cubit.state.tab, HomeTab.settings);
      expect(drawerSelected(tester), 8);
      expect(tester.takeException(), isNull);
    });

    testWidgets('drawer: a quick double tap on a page entry opens one page', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHome(tester, _Layout.desktop);

      await tester.tap(find.byIcon(Icons.account_balance_outlined));
      now = now.add(const Duration(milliseconds: 100));
      await tester.tap(find.byIcon(Icons.account_balance_outlined), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('pushed ${ScreenPaths.bank}'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.homepage, reason: 'only one page was on top of the shell');
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('notifications without an account open the login page', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = AuthenticationRepository();
      addTearDown(auth.dispose);
      await pumpHome(tester, _Layout.desktop, auth: auth);

      await tester.tap(find.text(tr.navigation.notice));
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.login);
    });

    testWidgets('rail: nine entries, scrolls in a short window with 2x text, the bank entry opens the bank', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(700, 400)
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpHome(tester, _Layout.tablet);

      expect(tester.takeException(), isNull, reason: 'no vertical overflow');
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(9));
      expect(rail.selectedIndex, 0);

      final bank = find.byIcon(Icons.account_balance_outlined);
      await tester.dragUntilVisible(bank, find.byType(HomeNavigationRail), const Offset(0, -80));
      await tester.pumpAndSettle();
      await tester.tap(bank);
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.bank);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.homepage);
      expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: the bottom bar keeps its three tabs and still switches them', (tester) async {
      tester.view
        ..physicalSize = const Size(390, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHome(tester, _Layout.phone);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(3));
      expect(find.text(tr.navigation.bank), findsNothing);
      expect(find.text(tr.navigation.activities), findsNothing);

      await tester.tap(find.text(tr.navigation.topics));
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.topic);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
      now = now.add(const Duration(seconds: 1));
      await tester.tap(find.text(tr.navigation.settings));
      await tester.pumpAndSettle();
      expect(location(), '/settings');
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 2);
      expect(tester.takeException(), isNull);
    });

    group('unread count on the notifications entry', () {
      late AppDatabase db;
      late SettingsRepository settings;

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        final storage = StorageProvider(db, {}, {});
        settings = SettingsRepository(storage);
        getIt
          ..registerSingleton<StorageProvider>(storage)
          ..registerSingleton<SettingsRepository>(settings);
        await settings.init();
      });

      tearDown(() async {
        await getIt.reset();
        await settings.dispose();
        await db.close();
      });

      Future<NotificationStateCubit> unread(int notice, int pm, int broadcast) async {
        final info = NotificationInfoRepository();
        final cubit = NotificationStateCubit(info)
          ..setAll(noticeCount: notice, personalMessageCount: pm, broadcastMessageCount: broadcast);
        addTearDown(() async {
          await cubit.close();
          await info.dispose();
        });
        return cubit;
      }

      Finder countIn(int count) =>
          find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.text('$count'));

      Future<void> pumpDesktop(
        WidgetTester tester, {
        required UserLoginInfo? user,
        required bool hint,
        int notices = 2,
        int messages = 1,
      }) async {
        // The database is only used from the real zone: drift timers left in the fake zone never run.
        await tester.runAsync(() => settings.setValue(SettingsKeys.showUnreadInfoHint, hint));
        expect(settings.currentSettings.showUnreadInfoHint, hint);
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final auth = AuthenticationRepository(user: user);
        addTearDown(auth.dispose);
        await pumpHome(tester, _Layout.desktop, auth: auth, notice: await unread(notices, messages, 0));
      }

      /// Let the drawer show a new state of the cubit. A cubit emits on a broadcast stream, so `BlocBuilder` hears it
      /// in a microtask. `pump()` without a scheduled frame only flushes microtasks at its end: the listener marks the
      /// builder dirty and schedules a frame then, which the next `pump()` draws.
      Future<void> showState(WidgetTester tester) async {
        await tester.pump();
        await tester.pump();
      }

      testWidgets('the real total of the notification state, with an account and the hint on', (tester) async {
        await pumpDesktop(tester, user: _alice, hint: true);
        expect(countIn(3), findsOneWidget);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsOneWidget);

        // Follows the state: read notices lower the count, nothing unread hides the badge.
        final notice = BlocProvider.of<NotificationStateCubit>(tester.element(find.byType(HomeNavigationDrawer)))
          ..decreaseNotice(2);
        expect(notice.state.total, 1);
        await showState(tester);
        expect(countIn(1), findsOneWidget);
        expect(countIn(3), findsNothing, reason: 'the old count is gone');
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsOneWidget);
        notice.decreasePersonalMessage();
        expect(notice.state.total, 0);
        await showState(tester);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsNothing);
        expect(countIn(1), findsNothing);
      });

      testWidgets('no badge when the unread hint setting is off', (tester) async {
        await pumpDesktop(tester, user: _alice, hint: false);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsNothing);
        expect(countIn(3), findsNothing);
      });

      testWidgets('no badge without an account', (tester) async {
        await pumpDesktop(tester, user: null, hint: true);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsNothing);
      });

      testWidgets('no badge when nothing is unread', (tester) async {
        await pumpDesktop(tester, user: _alice, hint: true, notices: 0, messages: 0);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsNothing);
        expect(countIn(0), findsNothing, reason: 'no "0" badge');
      });
    });
  });

  group('daily red packet entry', () {
    Future<void> pumpEntry(WidgetTester tester, Widget entry) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: Center(child: entry)),
          ),
        ),
      );
      await tester.pump();
    }

    Finder filledButtons() => find.byWidgetPredicate((w) => w is FilledButton);

    bool enabled(WidgetTester tester, Finder button) => tester.widget<ButtonStyleButton>(button).onPressed != null;

    Future<void> dispose(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('claimable: a double tap sends one request, then the claimed state never submits again', (
      tester,
    ) async {
      final calls = <String>[];
      final answer = Completer<Either<AppException, DailyRedPacketResult>>();
      AsyncEither<DailyRedPacketResult> claim(String hash) {
        calls.add(hash);
        return TaskEither(() => answer.future);
      }

      await pumpEntry(
        tester,
        DailyRedPacketEntry(uid: 1000, config: _config, formHash: 'hash', onCheck: () {}, claim: claim),
      );
      final button = find.ancestor(of: find.text(tr.redPacket.daily.tooltip), matching: filledButtons());
      expect(button, findsOneWidget);
      expect(enabled(tester, button), isTrue);

      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(calls, ['hash'], reason: 'one request for two quick taps');
      expect(enabled(tester, filledButtons()), isFalse, reason: 'disabled while the request runs');

      answer.complete(const Right(DailyRedPacketResult(ok: true, amount: '5', unit: 'coins')));
      await tester.pump();
      await tester.pump();
      final claimed = find.ancestor(of: find.text(tr.redPacket.daily.claimedToday), matching: filledButtons());
      expect(claimed, findsOneWidget);
      expect(enabled(tester, claimed), isFalse);

      await tester.tap(claimed, warnIfMissed: false);
      await tester.pump();
      expect(calls, hasLength(1));

      // Another account on the same page starts a new button: nothing of the claim above carries over.
      await pumpEntry(
        tester,
        DailyRedPacketEntry(uid: 2000, config: _config, formHash: 'hash', onCheck: () {}, claim: claim),
      );
      expect(find.text(tr.redPacket.daily.claimedToday), findsNothing, reason: 'another account claimed nothing');
      expect(
        enabled(tester, find.ancestor(of: find.text(tr.redPacket.daily.tooltip), matching: filledButtons())),
        isTrue,
      );
      expect(calls, hasLength(1));
      await dispose(tester);
    });

    testWidgets('"already claimed" from the server is the claimed state too', (tester) async {
      var calls = 0;
      await pumpEntry(
        tester,
        DailyRedPacketEntry(
          uid: 1000,
          config: _config,
          formHash: 'hash',
          onCheck: () {},
          claim: (_) {
            calls++;
            return TaskEither.right(const DailyRedPacketResult(ok: false, already: true));
          },
        ),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      expect(find.text(tr.redPacket.daily.claimedToday), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('a failed request keeps the packet claimable and records nothing', (tester) async {
      var calls = 0;
      await pumpEntry(
        tester,
        DailyRedPacketEntry(
          uid: 1000,
          config: _config,
          formHash: 'hash',
          onCheck: () {},
          claim: (_) {
            calls++;
            return TaskEither.left(HttpRequestFailedException(500));
          },
        ),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      expect(find.text(tr.redPacket.daily.claimedToday), findsNothing);
      final button = find.ancestor(of: find.text(tr.redPacket.daily.tooltip), matching: filledButtons());
      expect(enabled(tester, button), isTrue, reason: 'the user can try again');
      await dispose(tester);
    });

    testWidgets('no packet on the homepage: "none now" with a packet check, never "claimed"', (tester) async {
      var refreshes = 0;
      await pumpEntry(
        tester,
        DailyRedPacketEntry(uid: 1000, config: null, formHash: 'hash', onCheck: () => refreshes++),
      );
      expect(find.text(tr.redPacket.daily.unavailable), findsOneWidget);
      expect(find.text(tr.redPacket.daily.claimedToday), findsNothing);
      expect(find.text(tr.redPacket.daily.tooltip), findsNothing, reason: 'nothing claimable is made up');
      await tester.tap(find.text(tr.redPacket.daily.unavailable));
      await tester.pump();
      expect(refreshes, 1);

      // A packet without a form hash cannot be claimed either.
      await pumpEntry(tester, DailyRedPacketEntry(uid: 1000, config: _config, formHash: '', onCheck: () {}));
      expect(find.text(tr.redPacket.daily.unavailable), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('a reloaded page without a packet after a confirmed claim: none to claim, no date guessed', (
      tester,
    ) async {
      var refreshes = 0;
      await pumpEntry(
        tester,
        DailyRedPacketEntry(
          uid: 1000,
          config: _config,
          formHash: 'hash',
          onCheck: () => refreshes++,
          claim: (_) => TaskEither.right(const DailyRedPacketResult(ok: true, amount: '5', unit: 'coins')),
        ),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await tester.pump();
      await tester.pump();
      expect(find.text(tr.redPacket.daily.claimedToday), findsOneWidget);

      // The app knows no clock of the forum: without a packet on the page it cannot tell which day it is there, so it
      // does not say "claimed today"; the hint says it may be claimed already.
      await pumpEntry(
        tester,
        DailyRedPacketEntry(uid: 1000, config: null, formHash: null, onCheck: () => refreshes++),
      );
      expect(find.text(tr.redPacket.daily.claimedToday), findsNothing);
      expect(find.text(tr.redPacket.daily.unavailable), findsOneWidget);
      expect(find.byTooltip(tr.redPacket.daily.unavailableHint), findsOneWidget);
      await tester.tap(find.text(tr.redPacket.daily.unavailable));
      await tester.pump();
      expect(refreshes, 1);
      await dispose(tester);
    });

    testWidgets('without an account: says a login is needed', (tester) async {
      await pumpEntry(tester, DailyRedPacketEntry(uid: null, config: _config, formHash: 'hash', onCheck: () {}));
      expect(find.text(tr.redPacket.daily.needLogin), findsOneWidget);
      expect(find.text(tr.redPacket.daily.tooltip), findsNothing);
      await dispose(tester);
    });
  });

  group('greeting title badge', () {
    late StreamController<AuthStatus> auth;
    late CurrentTitleCubit cubit;
    late List<Completer<Either<AppException, List<SecondaryTitle>>>> pending;

    setUp(() {
      auth = StreamController<AuthStatus>.broadcast(sync: true);
      pending = [];
      cubit = CurrentTitleCubit(
        currentUid: () => _alice.uid,
        authStatus: auth.stream,
        fetchTitles: () => TaskEither(() {
          final completer = Completer<Either<AppException, List<SecondaryTitle>>>();
          pending.add(completer);
          return completer.future;
        }),
      );
      auth.add(const AuthStatusAuthed(_alice));
    });

    tearDown(() async {
      await cubit.close();
      await auth.close();
    });

    /// The greeting header in a [window], padded as in the card; [compact] for phones, [scale] for the text.
    Future<void> pumpHeader(
      WidgetTester tester, {
      required Size window,
      required bool compact,
      double scale = 1,
    }) async {
      tester.view
        ..physicalSize = window
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Page padding 12 and card padding 16 (phones) or 24 (wide) on each side, as on the homepage.
      final padding = compact ? 28.0 : 36.0;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: BlocProvider.value(
                value: cubit,
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(horizontal: padding, vertical: 16),
                  child: HomeGreetingHeader(
                    greeting: const Text('Good evening, Alice with a rather long name', key: ValueKey('greeting')),
                    uid: _alice.uid,
                    compact: compact,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// The title is read: the real badge widget. The workaround url is drawn without the image cache, so the box of the
    /// badge is measured without network or database.
    Future<void> completeTitle(WidgetTester tester) async {
      pending.single.complete(
        Right([SecondaryTitle(id: 1, name: 'T', imageUrl: tmpImpellerWorkaroundUrls.first, activated: true)]),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('desktop: the natural 184px wide, complete 184:100 box, beside the greeting', (tester) async {
      await pumpHeader(tester, window: const Size(1000, 600), compact: false);
      final expected = Size(184, SecondaryTitleBadge.heightFor(184));
      expect(tester.getSize(find.byType(SecondaryTitlePlaceholder)), expected, reason: 'room kept while loading');

      await completeTitle(tester);
      final badge = find.byType(SecondaryTitleBadge);
      expect(badge, findsOneWidget);
      expect(tester.getSize(badge), expected);
      expect(tester.getSize(badge).width / tester.getSize(badge).height, closeTo(184 / 100, 0.01));
      final greeting = tester.getRect(find.byKey(const ValueKey('greeting')));
      expect(tester.getRect(badge).left, greaterThan(greeting.right), reason: 'beside the greeting');
      expect(tester.getRect(badge).right, lessThanOrEqualTo(1000 - 36));
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone 412: 160 to 184px beside the greeting', (tester) async {
      await pumpHeader(tester, window: const Size(412, 800), compact: true);
      await completeTitle(tester);
      final size = tester.getSize(find.byType(SecondaryTitleBadge));
      expect(size.width, inInclusiveRange(160, 184));
      expect(size.height, closeTo(SecondaryTitleBadge.heightFor(size.width), 0.01));
      final greeting = tester.getRect(find.byKey(const ValueKey('greeting')));
      expect(tester.getRect(find.byType(SecondaryTitleBadge)).left, greaterThan(greeting.right));
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone 320 with 2x text: 160px below the greeting, nothing overflows', (tester) async {
      await pumpHeader(tester, window: const Size(320, 640), compact: true, scale: 2);
      await completeTitle(tester);
      expect(tester.takeException(), isNull);
      final badge = tester.getRect(find.byType(SecondaryTitleBadge));
      expect(badge.width, 160);
      expect(badge.height, closeTo(SecondaryTitleBadge.heightFor(160), 0.01));
      final greeting = tester.getRect(find.byKey(const ValueKey('greeting')));
      expect(badge.top, greaterThanOrEqualTo(greeting.bottom), reason: 'wrapped below the greeting');
      expect(badge.right, lessThanOrEqualTo(320 - 28));
      expect(badge.left, greeting.left, reason: 'the badge starts under the greeting, which keeps the whole width');
      expect(find.text('Good evening, Alice with a rather long name'), findsOneWidget);
    });
  });
}
