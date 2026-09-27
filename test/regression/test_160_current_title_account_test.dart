import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// The secondary title badge of the current account (homepage, own profile, medal & title hub) comes from the titles
/// page of that account. It must never show for another account: not after a switch, not after a logout, and not when
/// the answer of a request started for the previous account arrives late.
///
/// Synthetic accounts and titles, no network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

SecondaryTitle _title(int id, {bool activated = false}) =>
    SecondaryTitle(id: id, name: 'Title $id', imageUrl: 'https://example.invalid/title/$id.gif', activated: activated);

final class _Harness {
  _Harness() {
    cubit = CurrentTitleCubit(
      currentUid: () => currentUid,
      authStatus: auth.stream,
      fetchTitles: () => TaskEither(() {
        requests++;
        final completer = Completer<Either<AppException, List<SecondaryTitle>>>();
        pending.add(completer);
        return completer.future;
      }),
    );
  }

  final auth = StreamController<AuthStatus>.broadcast(sync: true);
  late final CurrentTitleCubit cubit;
  int? currentUid;
  int requests = 0;
  final pending = <Completer<Either<AppException, List<SecondaryTitle>>>>[];

  void login(UserLoginInfo user) {
    currentUid = user.uid;
    auth.add(AuthStatusAuthed(user));
  }

  Future<void> answer(List<SecondaryTitle> titles, {int index = 0}) async {
    pending[index].complete(Right(titles));
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    await cubit.close();
    await auth.close();
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late _Harness h;
  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  test('the title in use is read once for the account and only matches that account', () async {
    h.login(_alice);
    final loading = h.cubit.ensureLoaded();
    expect(h.cubit.state.status, CurrentTitleStatus.loading);
    // A second badge on screen does not read the page again.
    unawaited(h.cubit.ensureLoaded());
    await h.answer([_title(1), _title(2, activated: true)]);
    await loading;

    expect(h.requests, 1);
    expect(h.cubit.state.status, CurrentTitleStatus.success);
    expect(h.cubit.state.imageUrlFor(_alice.uid), 'https://example.invalid/title/2.gif');
    expect(h.cubit.state.imageUrlFor(_bob.uid), isNull, reason: 'never shown for another user');
    expect(h.cubit.state.imageUrlFor(null), isNull);

    await h.cubit.ensureLoaded();
    expect(h.requests, 1, reason: 'known already');
    final forced = h.cubit.ensureLoaded(force: true);
    await h.answer([_title(1)], index: 1);
    await forced;
    expect(h.requests, 2);
    expect(h.cubit.state.imageUrlFor(_alice.uid), isNull, reason: 'the title was unset meanwhile');
  });

  test('switching accounts drops the title at once and discards the late answer for the previous account', () async {
    h.login(_alice);
    final aliceLoad = h.cubit.ensureLoaded();

    // Switch while Alice's page is still loading.
    h.auth.add(const AuthStatusLoading());
    expect(h.cubit.state.uid, isNull);
    await h.cubit.ensureLoaded();
    expect(h.requests, 1, reason: 'nothing is read while the account changes');
    h.login(_bob);
    expect(h.cubit.state.uid, _bob.uid);

    await h.answer([_title(7, activated: true)]);
    await aliceLoad;
    expect(h.cubit.state.uid, _bob.uid);
    expect(h.cubit.state.title, isNull, reason: "Alice's title must not become Bob's");
    expect(h.cubit.state.imageUrlFor(_bob.uid), isNull);
    expect(h.cubit.state.imageUrlFor(_alice.uid), isNull);

    final bobLoad = h.cubit.ensureLoaded();
    await h.answer([_title(9, activated: true)], index: 1);
    await bobLoad;
    expect(h.cubit.state.imageUrlFor(_bob.uid), 'https://example.invalid/title/9.gif');
  });

  test('logging out forgets the title', () async {
    h.login(_alice);
    final load = h.cubit.ensureLoaded();
    await h.answer([_title(2, activated: true)]);
    await load;
    expect(h.cubit.state.imageUrlFor(_alice.uid), isNotNull);

    h
      ..currentUid = null
      ..auth.add(const AuthStatusNotAuthed());
    expect(h.cubit.state.uid, isNull);
    expect(h.cubit.state.title, isNull);
    expect(h.cubit.state.imageUrlFor(_alice.uid), isNull);
  });

  test('the my titles page hands its titles over only for the account it was opened with', () async {
    h.login(_alice);
    h.cubit.record(uid: _bob.uid, titles: [_title(3, activated: true)]);
    expect(h.cubit.state.title, isNull, reason: 'not the current account');

    h.cubit.record(uid: _alice.uid, titles: [_title(3, activated: true), _title(4)]);
    expect(h.cubit.state.status, CurrentTitleStatus.success);
    expect(h.cubit.state.imageUrlFor(_alice.uid), 'https://example.invalid/title/3.gif');

    // Unset on the page.
    h.cubit.record(uid: _alice.uid, titles: [_title(3), _title(4)]);
    expect(h.cubit.state.status, CurrentTitleStatus.success);
    expect(h.cubit.state.imageUrlFor(_alice.uid), isNull);
    await h.cubit.ensureLoaded();
    expect(h.requests, 0, reason: 'what the page read is enough');
  });

  test('a record supersedes a read still in flight', () async {
    h.login(_alice);
    final load = h.cubit.ensureLoaded();
    h.cubit.record(uid: _alice.uid, titles: [_title(5, activated: true)]);
    await h.answer([_title(6, activated: true)]);
    await load;
    expect(h.cubit.state.imageUrlFor(_alice.uid), 'https://example.invalid/title/5.gif');
  });

  test('a failed read is reported and retried on the next request', () async {
    h.login(_alice);
    final load = h.cubit.ensureLoaded();
    h.pending.single.complete(Left(HttpRequestFailedException(500)));
    await pumpEventQueue();
    await load;
    expect(h.cubit.state.status, CurrentTitleStatus.failure);
    expect(h.cubit.state.imageUrlFor(_alice.uid), isNull);

    final retry = h.cubit.ensureLoaded();
    expect(h.requests, 2);
    await h.answer([_title(8, activated: true)], index: 1);
    await retry;
    expect(h.cubit.state.imageUrlFor(_alice.uid), 'https://example.invalid/title/8.gif');
  });
}
