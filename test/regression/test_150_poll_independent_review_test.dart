import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/post/cubit/poll_create_cubit.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/post/utils/new_thread_status.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

import 'poll_fixtures.dart';

const _draft = PollDraft(
  subject: 'Synthetic poll',
  message: '',
  options: ['Alpha', 'Beta'],
  maxChoices: '1',
  expiry: '',
  visibleAfterVote: false,
  publicVoters: false,
  threadType: null,
  extraOptions: [],
);

PollCreateForm _form(String html) => PollCreateForm.parse(parseHtmlDocument(html), fid: '4', uid: 1000).form!;

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('special poll may omit type even when ordinary threads offer categories', () {
    expect(validatePollDraft(_draft, _form(pollForm(typeSelect: pollTypeSelect))).isValid, isTrue);
  });

  test('checking a default-off extra survives fresh validation and sends once', () async {
    final html = pollForm().replaceFirst(' checked="checked"', '');
    final form = _form(html);
    final draft = PollDraft(
      subject: _draft.subject,
      message: '',
      options: _draft.options,
      maxChoices: '1',
      expiry: '',
      visibleAfterVote: false,
      publicVoters: false,
      threadType: null,
      extraOptions: [form.extraOptions.single.copyWith(checked: true)],
    );
    var posts = 0;
    final repo = PollCreateRepository.withTransport(
      currentUid: () => 1000,
      getPage: (_) async => right(pollResponse(html)),
      sendForm: (_, payload) async {
        posts++;
        expect(payload['usesig'], '1');
        return right(pollResponse(''));
      },
    );
    final cubit = PollCreateCubit(repository: repo, fid: '4');
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.review(draft)!.isValid, isTrue);
    await cubit.confirm();
    expect(posts, 1);
  });

  test('comment or quoted maxoptions is not an executed limit declaration', () {
    for (final script in [
      "/* var maxoptions = parseInt('100'); */",
      '''var help = "maxoptions = parseInt('100');";''',
    ]) {
      final result = PollCreateForm.parse(parseHtmlDocument(pollForm(maxOptionsScript: script)), fid: '4', uid: 1000);
      expect(result.kind, PollFormParseKind.unsupported, reason: script);
    }
  });

  test('unknown required controls use the browser rather than dropping data', () {
    final html = pollForm(extra: '<input name="pluginRequired" required value="x">');
    expect(PollCreateForm.parse(parseHtmlDocument(html), fid: '4', uid: 1000).kind, PollFormParseKind.unsupported);
  });

  test('disabled bulk control is not an available bulk submission mode', () {
    final html = pollForm().replaceFirst('<textarea name="polloptions"', '<textarea disabled name="polloptions"');
    expect(PollCreateForm.parse(parseHtmlDocument(html), fid: '4', uid: 1000).kind, PollFormParseKind.unsupported);
  });

  test('rewritten canonical verifies the same visible thread', () {
    final html = pollThread().replaceFirst(
      'rel="canonical" href="forum.php?mod=viewthread&amp;tid=321"',
      'rel="canonical" href="/thread-321-1-1.html"',
    );
    expect(classifyNewThreadHeader(parseHtmlDocument(html), '321'), NewThreadHeaderStatus.visible);
  });

  test('author hidden status link is not public visibility', () {
    final html = pollThread(
      label:
          '<a class="psave" id="hiderecover" href="forum.php?mod=misc&amp;action=hiderecover&amp;tid=321">Hidden</a>',
    );
    expect(classifyNewThreadHeader(parseHtmlDocument(html), '321'), NewThreadHeaderStatus.unknown);
  });

  test('an unclassified message does not establish that no thread was created', () async {
    final repo = PollCreateRepository.withTransport(
      currentUid: () => 1000,
      getPage: (_) async => right(pollResponse(pollForm())),
      sendForm: (_, _) async => right(pollResponse(pollMessage('Synthetic intermediate response', cls: ''))),
    );
    final form = _form(pollForm());
    final result = await repo.submit(form, validatePollDraft(_draft, form).submission!);
    expect(result.outcome, PollCreateOutcome.unconfirmed);
  });

  test('revoked permission after review sends zero POSTs', () async {
    var denied = false;
    var posts = 0;
    final repo = PollCreateRepository.withTransport(
      currentUid: () => 1000,
      getPage: (_) async =>
          right(pollResponse(denied ? pollMessage('Permission revoked', cls: 'alert_error') : pollForm())),
      sendForm: (_, _) async {
        posts++;
        return right(pollResponse(''));
      },
    );
    final cubit = PollCreateCubit(repository: repo, fid: '4');
    addTearDown(cubit.close);
    await cubit.load();
    cubit.review(_draft);
    denied = true;
    await cubit.confirm();
    expect(posts, 0);
  });

  test('disposed editor ignores an already queued confirmation', () async {
    var posts = 0;
    final repo = PollCreateRepository.withTransport(
      currentUid: () => 1000,
      getPage: (_) async => right(pollResponse(pollForm())),
      sendForm: (_, _) async {
        posts++;
        return right(pollResponse(''));
      },
    );
    final cubit = PollCreateCubit(repository: repo, fid: '4');
    await cubit.load();
    cubit.review(_draft);
    await cubit.close();
    await cubit.confirm();
    expect(posts, 0);
  });

  test('interrupted send warning remains after A to B to A', () async {
    var uid = 1000;
    final auth = StreamController<AuthStatus>.broadcast();
    final pending = Completer<SyncEither<Response<dynamic>>>();
    final posted = Completer<void>();
    final repo = PollCreateRepository.withTransport(
      currentUid: () => uid,
      getPage: (_) async => right(pollResponse(pollForm())),
      sendForm: (_, _) {
        posted.complete();
        return pending.future;
      },
    );
    final cubit = PollCreateCubit(repository: repo, fid: '4', authChanges: auth.stream);
    addTearDown(() async {
      await cubit.close();
      await auth.close();
    });
    await cubit.load();
    cubit.review(_draft);
    final sending = cubit.confirm();
    await posted.future;
    uid = 1001;
    auth.add(const AuthStatusAuthed(UserLoginInfo(uid: 1001, username: 'B')));
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.interruptedSubmit, isTrue);
    pending.complete(right(pollResponse('')));
    await sending;
    uid = 1000;
    auth.add(const AuthStatusAuthed(UserLoginInfo(uid: 1000, username: 'A')));
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.interruptedSubmit, isTrue);
  });
}
