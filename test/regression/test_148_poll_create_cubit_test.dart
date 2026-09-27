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
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

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

AuthStatus _authed(int uid) => AuthStatusAuthed(UserLoginInfo(uid: uid, username: 'User $uid'));

final class _Env {
  _Env({Future<SyncEither<Response<dynamic>>> Function()? post, this.form}) : _postResult = post;

  final Future<SyncEither<Response<dynamic>>> Function()? _postResult;
  String Function()? form;
  int uid = 1000;
  int posts = 0;
  final auth = StreamController<AuthStatus>.broadcast();

  late final repo = PollCreateRepository.withTransport(
    currentUid: () => uid,
    getPage: (url) async =>
        right(pollResponse(url.contains('viewthread') ? pollThread() : (form?.call() ?? pollForm()))),
    sendForm: (_, _) {
      posts++;
      return _postResult?.call() ??
          Future.value(
            right<AppException, Response<dynamic>>(
              pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321'),
            ),
          );
    },
  );

  late final cubit = PollCreateCubit(repository: repo, fid: '4', authChanges: auth.stream);

  Future<void> reviewed() async {
    await cubit.load();
    expect(cubit.state.status, PollCreateStatus.editing);
    expect(cubit.review(_draft)!.isValid, isTrue);
    expect(cubit.state.status, PollCreateStatus.reviewing);
  }

  Future<void> close() async {
    await cubit.close();
    await auth.close();
  }
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

/// Wait until the fresh form check has finished and the POST was actually handed to the transport.
Future<void> _untilPosted(_Env env, {int posts = 1}) async {
  for (var i = 0; i < 50 && env.posts < posts; i++) {
    await _tick();
  }
  expect(env.posts, posts);
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('cancelling the confirmation sends nothing and keeps the form', () async {
    final env = _Env();
    addTearDown(env.close);
    await env.reviewed();
    env.cubit.cancelReview();
    expect(env.cubit.state.status, PollCreateStatus.editing);
    expect(env.cubit.state.form, isNotNull);
    expect(env.posts, 0);
  });

  test('invalid input never reaches the confirmation', () async {
    final env = _Env();
    addTearDown(env.close);
    await env.cubit.load();
    final result = env.cubit.review(
      const PollDraft(
        subject: '',
        message: '',
        options: ['Only'],
        maxChoices: '1',
        expiry: '00x',
        visibleAfterVote: false,
        publicVoters: false,
        threadType: null,
        extraOptions: [],
      ),
    );
    expect(result!.isValid, isFalse);
    expect(env.cubit.state.status, PollCreateStatus.editing);
    await env.cubit.confirm();
    expect(env.posts, 0);
  });

  test('double tap posts once and the published result is typed', () async {
    final pending = Completer<SyncEither<Response<dynamic>>>();
    final env = _Env(post: () => pending.future);
    addTearDown(env.close);
    await env.reviewed();
    final first = env.cubit.confirm();
    final second = env.cubit.confirm();
    expect(env.cubit.state.status, PollCreateStatus.checking);
    expect(env.cubit.canConfirm, isFalse);
    await _untilPosted(env);
    expect(env.cubit.state.status, PollCreateStatus.submitting);
    expect(env.cubit.canConfirm, isFalse);
    await env.cubit.confirm();
    pending.complete(right(pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321')));
    await Future.wait([first, second]);
    expect(env.posts, 1);
    expect(env.cubit.state.status, PollCreateStatus.published);
    expect(env.cubit.state.tid, '321');
  });

  test('unknown result blocks resending until the user explicitly resolves it', () async {
    final env = _Env(post: () async => left(HttpRequestFailedException(null)));
    addTearDown(env.close);
    await env.reviewed();
    await env.cubit.confirm();
    expect(env.cubit.state.status, PollCreateStatus.unconfirmed);
    expect(env.cubit.review(_draft), isNull);
    await env.cubit.confirm();
    await env.cubit.load();
    expect(env.posts, 1);
    expect(env.cubit.state.status, PollCreateStatus.unconfirmed);

    env.cubit.resolveUnconfirmed();
    expect(env.cubit.state.status, PollCreateStatus.editing);
    expect(env.cubit.review(_draft)!.isValid, isTrue);
    await env.cubit.confirm();
    expect(env.posts, 2);
  });

  test('explicit refusal keeps the form and allows an explicit resend', () async {
    final env = _Env(post: () async => right(pollResponse(pollMessage('Synthetic refusal', cls: 'alert_error'))));
    addTearDown(env.close);
    await env.reviewed();
    await env.cubit.confirm();
    expect(env.cubit.state.status, PollCreateStatus.rejected);
    expect(env.cubit.state.message, 'Synthetic refusal');
    expect(env.cubit.state.form, isNotNull);
    expect(env.cubit.review(_draft)!.isValid, isTrue);
    expect(env.posts, 1);
  });

  test('same-account verification keeps the confirmation', () async {
    final env = _Env();
    addTearDown(env.close);
    await env.reviewed();
    env.auth
      ..add(const AuthStatusLoading())
      ..add(_authed(1000));
    await _tick();
    expect(env.cubit.state.status, PollCreateStatus.reviewing);
    expect(env.cubit.canConfirm, isTrue);
  });

  test('A to B to A drops the confirmation and never revives the old form', () async {
    final env = _Env();
    addTearDown(env.close);
    await env.reviewed();
    env.uid = 1001;
    env.auth.add(_authed(1001));
    await _tick();
    expect(env.cubit.state.status, PollCreateStatus.identityChanged);
    expect(env.cubit.state.form, isNull);
    expect(env.cubit.state.submission, isNull);
    env.uid = 1000;
    env.auth.add(_authed(1000));
    await _tick();
    await env.cubit.confirm();
    await env.cubit.load();
    expect(env.cubit.review(_draft), isNull);
    expect(env.cubit.state.status, PollCreateStatus.identityChanged);
    expect(env.posts, 0);
  });

  test('a result arriving after an account switch is dropped and reported as interrupted', () async {
    final pending = Completer<SyncEither<Response<dynamic>>>();
    final env = _Env(post: () => pending.future);
    addTearDown(env.close);
    await env.reviewed();
    final sending = env.cubit.confirm();
    await _untilPosted(env);
    env.uid = 1001;
    env.auth.add(_authed(1001));
    await _tick();
    expect(env.cubit.state.status, PollCreateStatus.identityChanged);
    expect(env.cubit.state.interruptedSubmit, isTrue);
    pending.complete(right(pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321')));
    await sending;
    expect(env.cubit.state.status, PollCreateStatus.identityChanged);
    expect(env.cubit.state.tid, isNull);
    expect(env.posts, 1);
  });

  test('a slow older form load cannot replace a newer one', () async {
    final loads = <Completer<SyncEither<Response<dynamic>>>>[];
    final repo = PollCreateRepository.withTransport(
      currentUid: () => 1000,
      getPage: (_) {
        final completer = Completer<SyncEither<Response<dynamic>>>();
        loads.add(completer);
        return completer.future;
      },
      sendForm: (_, _) async => throw StateError('no post'),
    );
    final cubit = PollCreateCubit(repository: repo, fid: '4');
    addTearDown(cubit.close);
    final older = cubit.load();
    final newer = cubit.load();
    loads[1].complete(right(pollResponse(pollForm(maxOptionsScript: "var maxoptions = parseInt('7');"))));
    await newer;
    loads[0].complete(right(pollResponse(pollForm(maxOptionsScript: "var maxoptions = parseInt('3');"))));
    await older;
    expect(cubit.state.form!.maxOptions, 7);
  });

  test('expired login keeps the session and can reload the same account', () async {
    final env = _Env(form: () => pollForm(uid: 0));
    addTearDown(env.close);
    await env.cubit.load();
    expect(env.cubit.state.status, PollCreateStatus.loginRequired);
    env.form = pollForm;
    await env.cubit.load();
    expect(env.cubit.state.status, PollCreateStatus.editing);
  });

  test('a form served to another account invalidates the session', () async {
    final env = _Env(form: () => pollForm(uid: 1001));
    addTearDown(env.close);
    await env.cubit.load();
    expect(env.cubit.state.status, PollCreateStatus.identityChanged);
    env.form = pollForm;
    await env.cubit.load();
    expect(env.cubit.state.status, PollCreateStatus.identityChanged);
  });
}
