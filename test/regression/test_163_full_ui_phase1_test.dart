import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/card/post_card/show_user_brief_profile_dialog.dart';

/// Full UI redesign, phase 1: the secondary title (184x100 image) is shown complete and large enough on the homepage
/// greeting, floors and the author dialog; a failed read of the current account's title offers a retry instead of
/// looking like "no title"; the shared layout helpers behave on phones and wide windows.
///
/// Synthetic account and titles, no network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('secondary title sizes', () {
    // 2026-09-27: 240px on wide layouts; 2026-09-29: back to the natural 184px (the enlarged image was blurry).
    test('homepage greeting: the natural 184px on wide layouts, 160 to 184px on phones', () {
      expect(homeGreetingBadgeWidth(528, compact: false), homeGreetingBadgeWideWidth);
      expect(homeGreetingBadgeWidth(1200, compact: false), 184, reason: 'natural size, never enlarged (blurry)');
      expect(homeGreetingBadgeBeside(528, 184), isTrue);
    });

    test('homepage greeting: 160 to 184px on phones, beside the greeting only when it keeps its room', () {
      // 360, 390, 412 and 480 wide phones: page padding 12 and card padding 16 on each side.
      for (final window in [360.0, 390.0, 412.0, 480.0]) {
        final available = window - 56;
        final width = homeGreetingBadgeWidth(available, compact: true);
        expect(width, inInclusiveRange(160, 184), reason: '$window');
      }
      // 412 wide: beside the greeting, which keeps at least 168px.
      expect(homeGreetingBadgeBeside(356, homeGreetingBadgeWidth(356, compact: true)), isTrue);
      expect(homeGreetingBadgeLayout(356, compact: true), (
        width: homeGreetingBadgeWidth(356, compact: true),
        beside: true,
      ));
      // 384 wide (feedback 110): beside at 160 instead of below with the right half of the card empty.
      expect(homeGreetingBadgeLayout(328, compact: true), (width: 160.0, beside: true));
      // 360 wide: beside with the room left, not below 144.
      expect(homeGreetingBadgeLayout(304, compact: true), (width: 144.0, beside: true));
      // The same 360 wide phone with 1.3x text: the greeting keeps its room, the badge goes below at 160.
      expect(homeGreetingBadgeLayout(304, compact: true, textScale: 1.3), (width: 160.0, beside: false));
      expect(homeGreetingBadgeWidth(600, compact: true), 184);
      // Wide layouts keep the natural width beside the greeting.
      expect(homeGreetingBadgeLayout(528, compact: false), (width: 184.0, beside: true));
    });

    test('homepage greeting: the badge wraps below the greeting on very narrow windows', () {
      final width = homeGreetingBadgeWidth(264, compact: true);
      expect(width, 160, reason: 'not shrunk below 160 to squeeze beside the text');
      expect(homeGreetingBadgeBeside(264, width), isFalse);
      expect(homeGreetingBadgeLayout(264, compact: true), (width: 160.0, beside: false));
      // Never wider than the card.
      expect(homeGreetingBadgeWidth(150, compact: true), 150);
      expect(homeGreetingBadgeWidth(200, compact: false), 184);
      expect(homeGreetingBadgeWidth(150, compact: false), 150);
    });

    test('never wider than the room nor than the image', () {
      expect(SecondaryTitleBadge.fitWidth(100), 100);
      expect(SecondaryTitleBadge.fitWidth(1000), 184);
      expect(SecondaryTitleBadge.fitWidth(1000, preferred: 138), 138);
      expect(SecondaryTitleBadge.heightFor(120), closeTo(65.2, 0.1));
    });

    test('floor author row and author dialog', () {
      expect(SecondaryTitleBadge.heightFor(postAuthorSecondBadgeWidth(360)), closeTo(32, 0.001));
      expect(postAuthorSecondBadgeWidth(1280), postAuthorSecondBadgeWidth(360));
      expect(postAuthorSecondBadgeWidth(40), 40);
      for (final windowWidth in [320.0, 360.0, 1280.0]) {
        final width = SecondaryTitleBadge.fitWidth(
          briefProfileDialogContentWidth(windowWidth),
          preferred: SecondaryTitleBadge.widthFor(profileBadgeHeight),
        );
        expect(SecondaryTitleBadge.heightFor(width), closeTo(64, 0.001));
      }
    });
  });

  group('layout helpers', () {
    test('one column on phones, two on wide windows', () {
      expect(appColumnsFor(390), 1);
      expect(appColumnsFor(1024), 2);
      expect(appRowCount(5, 2), 3);
      expect(appRowCount(4, 1), 4);
    });

    test('lists are centered at their maximum width', () {
      expect(appCenteredPadding(390).horizontal, 24);
      expect(appCenteredPadding(1360).left, 200);
    });

    testWidgets('a state view with a long message fits a narrow window', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 480);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppStateView(message: 'A very long message ' * 30, action: const Text('action')),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('action'), findsOneWidget);
    });
  });

  group('current account title badge', () {
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

    Future<void> pumpBadge(WidgetTester tester, {int? uid = 1000}) => tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: BlocProvider.value(
              value: cubit,
              child: Center(child: CurrentAccountTitleBadge(uid: uid, width: 120)),
            ),
          ),
        ),
      ),
    );

    testWidgets('a failed read offers a retry, never "no title"', (tester) async {
      await pumpBadge(tester);
      expect(pending, hasLength(1));
      // The badge room is kept while the title is read.
      expect(tester.getSize(find.byType(SecondaryTitlePlaceholder)), Size(120, SecondaryTitleBadge.heightFor(120)));

      pending.single.complete(Left(HttpRequestFailedException(500)));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SecondaryTitleRetry), findsOneWidget);
      expect(find.byType(SecondaryTitlePlaceholder), findsNothing);

      await tester.tap(find.byType(SecondaryTitleRetry));
      await tester.pump();
      expect(pending, hasLength(2), reason: 'the retry reads the title again');
      expect(find.byType(SecondaryTitlePlaceholder), findsOneWidget);

      // Titles owned, none in use: nothing is shown, and nothing made up.
      pending[1].complete(Right([const SecondaryTitle(id: 3, name: 'T', imageUrl: 'x', activated: false)]));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SecondaryTitleRetry), findsNothing);
      expect(find.byType(SecondaryTitlePlaceholder), findsNothing);
      expect(find.byType(SecondaryTitleBadge), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('another user never gets the loading or retry room of the current account', (tester) async {
      await pumpBadge(tester, uid: 2000);
      expect(find.byType(SecondaryTitlePlaceholder), findsNothing);
      expect(find.byType(SecondaryTitleRetry), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
