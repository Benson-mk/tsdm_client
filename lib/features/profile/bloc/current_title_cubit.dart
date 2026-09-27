import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/features/profile/repository/my_titles_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Loading status of the secondary title of the current account.
enum CurrentTitleStatus {
  /// Nothing requested for [CurrentTitleState.uid] yet.
  initial,

  /// Fetching the titles page.
  loading,

  /// The current title is known, [CurrentTitleState.title] is null when none is used.
  success,

  /// Fetching failed, a later [CurrentTitleCubit.ensureLoaded] tries again.
  failure,
}

/// The secondary title the current account is using, keyed by the account it was read for.
@immutable
final class CurrentTitleState {
  /// Constructor.
  const CurrentTitleState({this.uid, this.status = CurrentTitleStatus.initial, this.title});

  /// Uid of the account [title] belongs to, null when no account is logged in.
  final int? uid;

  /// Loading status.
  final CurrentTitleStatus status;

  /// The title in use, from the `当前使用的称号` block of the titles page.
  final SecondaryTitle? title;

  /// Image of [title] when it belongs to the account [uid], null otherwise.
  ///
  /// Callers pass the uid of the user they are showing, so the badge of the current account never shows up for
  /// anybody else, nor for the previous account while switching.
  String? imageUrlFor(int? uid) => uid != null && uid == this.uid ? title?.imageUrl : null;

  /// [status] when it is about the account [uid], [CurrentTitleStatus.initial] otherwise.
  ///
  /// Lets a badge tell "not known yet" or "failed to read" apart from "no title in use" for that account only.
  CurrentTitleStatus statusFor(int? uid) => uid != null && uid == this.uid ? status : CurrentTitleStatus.initial;

  @override
  bool operator ==(Object other) =>
      other is CurrentTitleState && other.uid == uid && other.status == status && other.title == title;

  @override
  int get hashCode => Object.hash(uid, status, title);
}

/// App level holder of the secondary title used by the current account.
///
/// The forum renders the title of an author next to their posts, but the pages about the current account (homepage,
/// own profile) do not carry it: the only source is the title management page of the account itself
/// (`plugin.php?id=tsdmtitle:tsdmtitle`). That page is read once per account and only when a badge is about to be
/// shown ([ensureLoaded]); the my titles page hands over what it read or switched to ([record]) so nothing is fetched
/// twice.
///
/// Every account change drops the known title at once and discards answers of requests started for the previous
/// account.
final class CurrentTitleCubit extends Cubit<CurrentTitleState> with LoggerMixin {
  /// Constructor.
  ///
  /// [currentUid] is the verified current account, [authStatus] its changes; [fetchTitles] reads the titles page of
  /// the current account (replaceable in tests).
  CurrentTitleCubit({
    required int? Function() currentUid,
    required Stream<AuthStatus> authStatus,
    AsyncEither<List<SecondaryTitle>> Function()? fetchTitles,
  }) : _currentUid = currentUid,
       _fetchTitles = fetchTitles ?? _defaultFetchTitles,
       super(const CurrentTitleState()) {
    _authSub = authStatus.listen(_onAuthStatus);
  }

  // A new repository per request: it caches the form hash of the session it was used in.
  static AsyncEither<List<SecondaryTitle>> _defaultFetchTitles() => MyTitlesRepository().fetchSecondaryTitles();

  final int? Function() _currentUid;
  final AsyncEither<List<SecondaryTitle>> Function() _fetchTitles;
  late final StreamSubscription<AuthStatus> _authSub;

  /// Bumped whenever the known title is replaced or dropped; a request finishing under another generation is stale.
  int _generation = 0;

  void _reset(int? uid) {
    _generation++;
    emit(CurrentTitleState(uid: uid));
  }

  /// A login or an account switch is in progress: the cookie in use may already belong to the next account.
  bool _authChanging = false;

  void _onAuthStatus(AuthStatus status) {
    _authChanging = status is AuthStatusLoading;
    switch (status) {
      case AuthStatusAuthed(:final userInfo):
        if (userInfo.uid != state.uid) {
          _reset(userInfo.uid);
        }
      case AuthStatusNotAuthed() || AuthStatusLoading():
        // Logging out or switching: nothing about the previous account may stay on screen, and whatever is in flight
        // for it is stale.
        _reset(null);
      case AuthStatusUnknown():
        break;
    }
  }

  /// Read the title of the current account unless it is known or being read; [force] reads it again.
  Future<void> ensureLoaded({bool force = false}) async {
    final uid = _currentUid();
    if (_authChanging) {
      return;
    }
    if (uid == null) {
      if (state.uid != null) {
        _reset(null);
      }
      return;
    }
    if (uid != state.uid) {
      _reset(uid);
    }
    if (state.status == CurrentTitleStatus.loading || (!force && state.status == CurrentTitleStatus.success)) {
      return;
    }
    final generation = _generation;
    emit(CurrentTitleState(uid: uid, status: CurrentTitleStatus.loading, title: state.title));
    final result = await _fetchTitles().run();
    if (isClosed || generation != _generation || _currentUid() != uid) {
      debug('drop the title read for uid $uid: the account changed meanwhile');
      return;
    }
    switch (result) {
      case Right(:final value):
        emit(
          CurrentTitleState(
            uid: uid,
            status: CurrentTitleStatus.success,
            title: value.firstWhereOrNull((e) => e.activated),
          ),
        );
      case Left(:final value):
        handle(value);
        emit(CurrentTitleState(uid: uid, status: CurrentTitleStatus.failure, title: state.title));
    }
  }

  /// Take the [titles] the my titles page read or switched for the account [uid].
  ///
  /// Ignored when [uid] is not the current account any more.
  void record({required int? uid, required List<SecondaryTitle> titles}) {
    if (uid == null || uid != _currentUid()) {
      return;
    }
    _generation++;
    emit(
      CurrentTitleState(
        uid: uid,
        status: CurrentTitleStatus.success,
        title: titles.firstWhereOrNull((e) => e.activated),
      ),
    );
  }

  @override
  Future<void> close() async {
    await _authSub.cancel();
    await super.close();
  }
}
