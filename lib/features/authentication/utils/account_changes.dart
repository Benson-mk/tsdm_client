import 'dart:async';

import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';

/// Follow the account of [auth] for a page that loaded for the current one: [onLoggingIn] when a login starts (the
/// page clears what it shows), [onChanged] when the account changed or a login ended.
///
/// The status stream replays the current status to a new listener. Pages reloaded on every status, so they loaded
/// twice when opened; the forum's app API answers the second call of an action within a few seconds "too soon" (HTTP
/// 429), and the page waited or fell back to a web page its parser may not know. The replayed status of the account
/// the page loaded for is not a change.
StreamSubscription<AuthStatus> listenAccountChanges(
  AuthenticationRepository auth, {
  required void Function() onLoggingIn,
  required void Function() onChanged,
}) {
  var shownUid = auth.effectiveCurrentUid;
  var loggingIn = false;
  return auth.status.listen((status) {
    if (status is AuthStatusLoading) {
      loggingIn = true;
      onLoggingIn();
      return;
    }
    final uid = auth.effectiveCurrentUid;
    if (!loggingIn && uid == shownUid) return;
    loggingIn = false;
    shownUid = uid;
    onChanged();
  });
}

/// Call [onLogin] after each login of the account [uid] that ends from now on, whichever page it was done from.
///
/// Also a login of the account in use again, which is no change for [listenAccountChanges]: the forum may have dropped
/// the session of that account (issue #25), and what it served meanwhile as to a guest changes after the login. The
/// status the stream replays to a new listener ([AuthenticationRepository.latestStatus]) ended before, it is no login.
StreamSubscription<AuthStatus> listenLoginsOf(
  AuthenticationRepository auth,
  int uid, {
  required void Function() onLogin,
}) {
  final replayed = auth.latestStatus;
  return auth.status.listen((status) {
    if (!identical(status, replayed) && _isLoginOf(status, uid)) {
      onLogin();
    }
  });
}

/// Whether the latest status of [auth] ([AuthenticationRepository.latestStatus]) is a login of the account [uid] that
/// ended after [since], a latest status read earlier.
///
/// For code that did not listen meanwhile ([listenLoginsOf] from then on would take that login for the replayed
/// status): a request sent before the login went out with the session the forum may have dropped (issue #25).
bool loggedInSince(AuthenticationRepository auth, AuthStatus? since, int uid) {
  final latest = auth.latestStatus;
  return !identical(latest, since) && _isLoginOf(latest, uid);
}

bool _isLoginOf(AuthStatus? status, int uid) => status is AuthStatusAuthed && status.userInfo.uid == uid;
