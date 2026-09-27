import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/post/view/poll_create_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

import 'poll_fixtures.dart';

/// Independent route-lifetime probes. All responses and content are synthetic.
final class _PollRouteHarness {
  final navigator = GlobalKey<NavigatorState>();
  final authChanges = StreamController<AuthStatus>.broadcast();
  int uid = 1000;
  int posts = 0;

  Future<void> openAndReview(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 3200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(authChanges.close);
    final auth = AuthenticationRepository(user: const UserLoginInfo(uid: 1000, username: 'Synthetic account'));
    addTearDown(auth.dispose);
    await LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Underlying forum')),
          ),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => PollCreatePage(
            fid: '4',
            authChanges: authChanges.stream,
            repositoryBuilder: (_) => PollCreateRepository.withTransport(
              currentUid: () => uid,
              getPage: (url) async => right(pollResponse(url.contains('viewthread') ? pollThread() : pollForm())),
              sendForm: (_, _) {
                posts++;
                return Future.value(
                  right<AppException, Response<dynamic>>(
                    pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Subject'), 'Private poll subject');
    await tester.enterText(find.widgetWithText(TextField, 'Choice 1'), 'Private choice Alpha');
    await tester.enterText(find.widgetWithText(TextField, 'Choice 2'), 'Private choice Beta');
    await tester.pump();
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm poll'), findsOneWidget);
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('a stale confirm callback cannot POST after its page has been popped', (tester) async {
    final harness = _PollRouteHarness();
    await harness.openAndReview(tester);
    final confirm = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Create poll'), matching: find.byWidgetPredicate((widget) => widget is FilledButton)),
    );
    final staleConfirm = confirm.onPressed;
    expect(staleConfirm, isNotNull);

    harness.navigator.currentState!.pop();
    // The route has left the stack, but its widget/cubit are still alive for the reverse animation.
    // Simulate a late callback already obtained from the old confirmation; do not wait for disposal.
    expect(find.byType(PollCreatePage), findsOneWidget);
    staleConfirm!();
    await tester.pump();

    expect(harness.posts, 0, reason: 'Returning to the forum ends this confirmation immediately.');
    await tester.pumpAndSettle();
    expect(find.text('Underlying forum'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an account change clears a poll confirmation that is already animating out', (tester) async {
    final harness = _PollRouteHarness();
    await harness.openAndReview(tester);
    harness.navigator.currentState!.pop();
    await tester.pump();
    expect(find.byType(PollCreatePage), findsOneWidget, reason: 'The reverse animation has not completed.');

    harness.uid = 1001;
    harness.authChanges.add(const AuthStatusAuthed(UserLoginInfo(uid: 1001, username: 'Other synthetic account')));
    await tester.idle();
    await tester.pump();

    expect(find.text('Private poll subject'), findsNothing);
    expect(find.textContaining('Private choice'), findsNothing);
    expect(harness.posts, 0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
