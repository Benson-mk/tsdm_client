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

final class _Page {
  _Page({this.form, this.post});

  String Function()? form;
  Future<SyncEither<Response<dynamic>>> Function()? post;
  int uid = 1000;
  int posts = 0;
  Map<String, String>? payload;
  final auth = StreamController<AuthStatus>.broadcast();

  Future<void> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 3200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final authRepository = AuthenticationRepository(user: const UserLoginInfo(uid: 1000, username: 'Test'));
    addTearDown(authRepository.dispose);
    addTearDown(auth.close);
    await LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: authRepository,
        child: TranslationProvider(
          child: MaterialApp(
            home: PollCreatePage(
              fid: '4',
              authChanges: auth.stream,
              repositoryBuilder: (_) => PollCreateRepository.withTransport(
                currentUid: () => uid,
                getPage: (url) async => right(
                  pollResponse(url.contains('viewthread') ? pollThread() : (form?.call() ?? pollForm())),
                ),
                sendForm: (_, body) {
                  posts++;
                  payload = body;
                  return post?.call() ??
                      Future.value(
                        right<AppException, Response<dynamic>>(
                          pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321'),
                        ),
                      );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Finder _field(String label) => find.widgetWithText(TextField, label);

Finder _button<T extends Widget>(String text) =>
    find.ancestor(of: find.text(text), matching: find.byWidgetPredicate((w) => w is T));

Future<void> _fill(WidgetTester tester, {String subject = 'Synthetic poll'}) async {
  await tester.enterText(_field('Subject'), subject);
  await tester.enterText(_field('Choice 1'), 'Alpha');
  await tester.enterText(_field('Choice 2'), 'Beta');
  await tester.pump();
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('choice rows follow the forum limit and the body is optional', (tester) async {
    final page = _Page(form: () => pollForm(maxOptionsScript: "var maxoptions = parseInt('4');"));
    await page.pump(tester);
    expect(find.text('Body (optional)'), findsOneWidget);
    expect(_field('Choice 3'), findsOneWidget);
    await tester.tap(find.text('Add choice'));
    await tester.pump();
    expect(_field('Choice 4'), findsOneWidget);
    expect(tester.widget<TextButton>(_button<TextButton>('Add choice')).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid input shows field errors without a confirmation', (tester) async {
    final page = _Page();
    await page.pump(tester);
    await tester.enterText(_field('Choice 1'), 'Only');
    await tester.tap(find.text('Review'));
    await tester.pump();
    expect(find.text('Subject cannot be empty'), findsOneWidget);
    expect(find.text('At least 2 non-empty choices are required'), findsOneWidget);
    expect(find.text('Confirm poll'), findsNothing);
    expect(page.posts, 0);
  });

  testWidgets('confirmation shows the exact poll and going back sends nothing', (tester) async {
    final page = _Page();
    await page.pump(tester);
    await _fill(tester);
    await tester.enterText(_field('Duration (days)'), '00');
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm poll'), findsOneWidget);
    expect(find.text('(no body)'), findsOneWidget);
    expect(find.text('1. Alpha'), findsOneWidget);
    expect(find.text('2. Beta'), findsOneWidget);
    expect(find.text('Single choice'), findsOneWidget);
    expect(find.text('No end date'), findsOneWidget);
    await tester.tap(find.text('Back to edit'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(page.posts, 0);
  });

  testWidgets('double tap on confirm posts once and shows the verified result', (tester) async {
    final pending = Completer<SyncEither<Response<dynamic>>>();
    final page = _Page(post: () => pending.future);
    await page.pump(tester);
    await _fill(tester);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    final confirm = _button<FilledButton>('Create poll');
    await tester.tap(confirm);
    await tester.tap(confirm, warnIfMissed: false);
    await tester.pump();
    expect(page.posts, 1);
    expect(page.payload!['polloptions'], 'Alpha\nBeta');
    expect(page.payload!['expiration'], '');
    pending.complete(right(pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Poll published'), findsOneWidget);
    expect(find.text('Open new thread'), findsOneWidget);
    expect(page.posts, 1);
  });

  testWidgets('unknown result keeps input but blocks sending until explicitly resolved', (tester) async {
    final page = _Page(post: () async => left(HttpRequestFailedException(null)));
    await page.pump(tester);
    await _fill(tester);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(_button<FilledButton>('Create poll'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Result unknown'), findsOneWidget);
    expect(find.text('Review'), findsNothing);
    await tester.tap(find.text('I checked it was not created, edit again'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(page.posts, 1);
  });

  testWidgets('forum refusal keeps the input and shows the plain message', (tester) async {
    final page = _Page(post: () async => right(pollResponse(pollMessage('Synthetic refusal', cls: 'alert_error'))));
    await page.pump(tester);
    await _fill(tester);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(_button<FilledButton>('Create poll'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic refusal'), findsOneWidget);
    expect(find.text('Synthetic poll'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('account switch clears the private input', (tester) async {
    final page = _Page();
    await page.pump(tester);
    await _fill(tester);
    page
      ..uid = 1001
      ..auth.add(const AuthStatusAuthed(UserLoginInfo(uid: 1001, username: 'Other')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your account changed'), findsOneWidget);
    expect(find.text('Synthetic poll'), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    expect(page.posts, 0);
  });

  testWidgets('unsupported form offers only the browser', (tester) async {
    final page = _Page(form: () => pollForm(plugin: '<input name="pollplusviewcredit" value="5">'));
    await page.pump(tester);
    expect(find.textContaining('does not support'), findsOneWidget);
    expect(find.text('Create poll in browser'), findsOneWidget);
    expect(find.text('Review'), findsNothing);
  });
}
