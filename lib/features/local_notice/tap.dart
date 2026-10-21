import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// What the app does with a tap on the auto sync notification.
enum LocalNoticeTapAction {
  /// No account in use: the notice page needs a login, stay where we are.
  needLogin,

  /// The notice page is already the page on top, nothing to open.
  alreadyOnNoticePage,

  /// A notice page is open under the pages on top, close those to show it again.
  returnToNoticePage,

  /// Push the notice page.
  openNoticePage,
}

/// Decide what a tap on the auto sync notification does.
///
/// [topLocation] is the location of the page the router shows on top ([routerTopLocation]). That is the only thing
/// telling whether the notice page is really in front: the location stack kept by `RootLocationCubit` is fed by page
/// enter/leave events and used to drift, so a tap on the homepage was answered "already in the notice page" after the
/// notice page had been left once (GitHub #14).
///
/// [canReturnToNoticePage] tells whether a notice page further down can be shown again ([canReturnToPage]). Each tap
/// while reading a thread opened out of the notice page used to push another notice page, piling them up (GitHub #117).
LocalNoticeTapAction decideLocalNoticeTap({
  required bool loggedIn,
  required String? topLocation,
  bool canReturnToNoticePage = false,
}) {
  if (!loggedIn) {
    return LocalNoticeTapAction.needLogin;
  }
  if (topLocation == ScreenPaths.notice) {
    return LocalNoticeTapAction.alreadyOnNoticePage;
  }
  if (canReturnToNoticePage) {
    return LocalNoticeTapAction.returnToNoticePage;
  }
  return LocalNoticeTapAction.openNoticePage;
}

/// Carry out a tap on the auto sync notification on [router].
///
/// Returns the page that was on top before and what was done: [LocalNoticeTapAction.openNoticePage] also when going
/// back to the open notice page stopped early (a page refused to close) and another one was pushed instead. [hasPopup]
/// tells whether a dialog or sheet is open, the pages under it are then never closed.
({String? top, LocalNoticeTapAction action}) openNoticePageForTap(
  GoRouter router, {
  required bool loggedIn,
  required bool hasPopup,
}) {
  final top = routerTopLocation(router);
  var action = decideLocalNoticeTap(
    loggedIn: loggedIn,
    topLocation: top,
    canReturnToNoticePage: canReturnToPage(router, ScreenPaths.notice, hasPopup: hasPopup),
  );
  if (action == LocalNoticeTapAction.returnToNoticePage && !returnToPage(router, ScreenPaths.notice)) {
    action = LocalNoticeTapAction.openNoticePage;
  }
  if (action == LocalNoticeTapAction.openNoticePage) {
    // Completes only when the pushed page is closed, nothing to wait for.
    unawaited(router.pushNamed(ScreenPaths.notice));
  }
  return (top: top, action: action);
}

/// Open the notice page from a control inside the app: the bell of the app bars, the "notifications" item of their
/// menu and of the profile page's menu. Every way into the notice page goes through here or [openNoticePageForTap]
/// and nowhere pushes it by itself (a regression test checks the sources).
///
/// The same as a tap on the auto sync notification: a notice page already open under the pages on top is shown again
/// when they can all be closed quietly, otherwise one is pushed. Reading the notices one by one (notice page, a
/// thread, the bell of the thread page, the next thread...) pushed another notice page each time and piled them up,
/// as the notification tap did before GitHub #117 (GitHub #196).
///
/// The account is not checked here: the controls are only offered with one, and the notice page asks for a login
/// itself, as before. [popups] is the observer of the app's dialogs and menus ([popupRouteObserver] by default): with
/// one open the pages under it are never closed. A menu item runs after its menu closed, so it does not count.
void openNoticePageInApp(BuildContext context, {PopupRouteObserver? popups}) {
  final (:top, :action) = openNoticePageForTap(
    GoRouter.of(context),
    loggedIn: true,
    hasPopup: (popups ?? popupRouteObserver).hasPopupRoute,
  );
  talker.debug('open notice page in app: action=${action.name} top=$top');
}

/// What a tap on the notification of an account did about the account, see [openNoticePageOfAccount].
enum LocalNoticeAccountStep {
  /// The notification is about the account in use, names no account, or no account is in use: nothing to switch.
  current,

  /// Switched to the account of the notification, then the notice page was opened.
  switched,

  /// The account of the notification is no longer saved on this device: nothing opened, a toast says so.
  gone,

  /// The switch did not happen (it failed, the login expired, a reply was being sent, another switch ran, the sync
  /// kept fetching): nothing opened, the switch told why.
  notSwitched,
}

/// Switch to [account] the way the avatar menu does (PR #187): [switchAccount] with a bloc of its own.
Future<SwitchAccountResult> _switchLikeTheMenu(BuildContext context, UserLoginInfo account) async {
  final bloc = SwitchUserBloc(context.read<AuthenticationRepository>());
  try {
    return await switchAccount(context, bloc: bloc, userInfo: account);
  } finally {
    // The switch has ended by now (see [switchAccount]): closing the bloc stops nothing.
    await bloc.close();
  }
}

/// Carry out a tap on an auto sync notification about account [uid] from [context], a page under the app's providers
/// (the home page). [uid] is null for a notification that names no account (only the account in use is announced, or
/// the test notification of the settings page): the account in use.
///
/// * The account in use, no account named, or nobody logged in: [openNoticePageForTap] right away, as before.
/// * Another account saved on this device: switch to it first, the same way as the avatar menu's quick switch
///   ([switchTo], [switchAccount] by default: its toasts, one switch at a time, none while a reply is being sent, the
///   in-app sync paused around it), then open the notice page once its lists are the new account's. Every
///   logged-in account is announced when asked to, and the account in use may have changed since any notification
///   was posted.
/// * At a cold start (the stored login not verified yet) the switch waits up to [settleTimeout] for the homepage to
///   verify it: switching while that check runs with the stored account's cookie mixed the two accounts up.
/// * The switch does not happen: nothing is opened, the notice page would show the account in use and not the one the
///   notification is about.
/// * An account no longer on this device: nothing is opened, a toast says so.
///
/// Returns what was done about the account, and, when the notice page was asked for, the page that was on top before
/// and what was done ([openNoticePageForTap]). [popups] is the observer of the app's dialogs and menus
/// ([popupRouteObserver] by default).
Future<({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})> openNoticePageOfAccount(
  BuildContext context, {
  required int? uid,
  PopupRouteObserver? popups,
  Future<SwitchAccountResult> Function(BuildContext context, UserLoginInfo account)? switchTo,
  Duration settleTimeout = const Duration(seconds: 10),
  Duration reloadTimeout = const Duration(seconds: 5),
}) async {
  ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action}) open(
    LocalNoticeAccountStep step, {
    required bool loggedIn,
  }) {
    final (:top, :action) = openNoticePageForTap(
      GoRouter.of(context),
      loggedIn: loggedIn,
      hasPopup: (popups ?? popupRouteObserver).hasPopupRoute,
    );
    return (step: step, top: top, action: action);
  }

  const notOpened = (step: LocalNoticeAccountStep.notSwitched, top: null, action: null);
  final auth = context.read<AuthenticationRepository>();
  // The stored session counts: when a notification cold-starts the app the home page has its first frame before the
  // homepage fetch verified the login, and `currentUser` is still null at that point (#14).
  var current = auth.effectiveCurrentUid;
  if (uid == null || current == null || uid == current) {
    return open(LocalNoticeAccountStep.current, loggedIn: current != null);
  }
  talker.info('notification of another account tapped: uid ${"$uid".obscured(4)}, switching to it first');
  if (auth.currentUser == null) {
    await _storedLoginSettled(auth, settleTimeout);
    if (!context.mounted) {
      return notOpened;
    }
    current = auth.effectiveCurrentUid;
    if (current == null || current == uid) {
      return open(LocalNoticeAccountStep.current, loggedIn: current != null);
    }
  }
  final account = (await getIt.get<StorageProvider>().getAllUsers()).firstWhereOrNull((e) => e.uid == uid);
  if (!context.mounted) {
    return notOpened;
  }
  if (account == null) {
    showSnackBar(context: context, message: context.t.localNotification.accountGone);
    return (step: LocalNoticeAccountStep.gone, top: null, action: null);
  }
  final result = await (switchTo ?? _switchLikeTheMenu)(context, account);
  if (result != SwitchAccountResult.switched || !context.mounted) {
    talker.info('notification of another account: not switched (${result.name}), notice page not opened');
    return notOpened;
  }
  if (context.readOrNull<NotificationBloc>() case final bloc?) {
    await _noticesReloadedFor(bloc, uid, reloadTimeout);
    if (!context.mounted) {
      return notOpened;
    }
  }
  return open(LocalNoticeAccountStep.switched, loggedIn: true);
}

/// Wait up to [timeout] for the first settled status of [auth] (logged in, or not): at a cold start the homepage
/// verifies the stored login, and a switch meanwhile raced it. Nothing settles when that login expired: the wait
/// then ends at [timeout], and a page of the stored account arriving after the switch records nothing (see
/// `AuthenticationRepository.loginWithServedUser`).
Future<void> _storedLoginSettled(AuthenticationRepository auth, Duration timeout) async {
  bool settled(AuthStatus? s) => s is AuthStatusAuthed || s is AuthStatusNotAuthed;
  if (settled(auth.latestStatus)) {
    return;
  }
  talker.info('waiting for the stored login to be verified before switching');
  try {
    // A closed stream (the app going away) ends the wait as well.
    await auth.status.firstWhere(settled, orElse: () => const AuthStatusUnknown()).timeout(timeout);
  } on TimeoutException {
    talker.warning('the stored login was not verified within ${timeout.inSeconds}s, switching anyway');
  }
}

/// Wait up to [timeout] for the lists of [bloc] to be the ones of [uid], not loading.
///
/// A fetch of the previous account still running ends dropped (its account is not the one in use any more, the state
/// is reset), then the lists are rebuilt from storage for [uid]; without one they are rebuilt right away. The page
/// shows nothing of another account meanwhile anyway ([NotificationState.ownerUid]).
Future<void> _noticesReloadedFor(NotificationBloc bloc, int uid, Duration timeout) async {
  bool ready(NotificationState s) => s.ownerUid == uid && s.status != NotificationStatus.loading;
  if (ready(bloc.state)) {
    return;
  }
  // A closed bloc (the app going away) ends the wait as well.
  final reached = bloc.stream.firstWhere(ready, orElse: () => bloc.state);
  void reload() {
    if (!bloc.isClosed) {
      bloc.add(NotificationReloadFromStorageRequested());
    }
  }

  if (bloc.state.status == NotificationStatus.loading) {
    unawaited(
      bloc.stream
          .firstWhere((s) => s.status != NotificationStatus.loading, orElse: () => bloc.state)
          .timeout(timeout, onTimeout: () => bloc.state)
          .then((_) => reload()),
    );
  } else {
    reload();
  }
  try {
    await reached.timeout(timeout);
  } on TimeoutException {
    talker.warning('the notices of the new account were not in within ${timeout.inSeconds}s, opening the page anyway');
  }
}

/// Location of the page on top of [router], `null` before the first route matched.
///
/// Walks into shell routes, so a page inside the home shell reports its own location instead of the shell's, and a
/// page opened with `pushNamed` reports itself. Dialogs and bottom sheets are not routes of the router: the page
/// under them is reported, which is what a tap wants to know.
String? routerTopLocation(GoRouter router) => router.routerDelegate.currentConfiguration.lastOrNull?.matchedLocation;
