import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
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
/// (the home page). [uid] is null for a notification that names no account (posted before notifications named it, or
/// the test notification of the settings page): the account in use.
///
/// * The account in use, no account named, or nobody logged in: [openNoticePageForTap] right away, as before.
/// * Another account saved on this device: switch to it first, the same way as the avatar menu's quick switch
///   ([switchTo], [switchAccount] by default: its toasts, one switch at a time, none while a reply is being sent, the
///   in-app sync paused around it), then reload the notice lists for it and open the notice page. The background
///   message service announces every saved account when asked to, and the account in use may have changed since any
///   notification was posted.
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
}) async {
  bool hasPopup() => (popups ?? popupRouteObserver).hasPopupRoute;
  // The stored session counts: when a notification cold-starts the app the home page has its first frame before the
  // homepage fetch verified the login, and `currentUser` is still null at that point (#14).
  final current = context.read<AuthenticationRepository>().effectiveCurrentUid;
  if (uid == null || current == null || uid == current) {
    final (:top, :action) = openNoticePageForTap(GoRouter.of(context), loggedIn: current != null, hasPopup: hasPopup());
    return (step: LocalNoticeAccountStep.current, top: top, action: action);
  }
  talker.info('notification of another account tapped: uid ${"$uid".obscured(4)}, switching to it first');
  final account = (await getIt.get<StorageProvider>().getAllUsers()).firstWhereOrNull((e) => e.uid == uid);
  if (!context.mounted) {
    return (step: LocalNoticeAccountStep.notSwitched, top: null, action: null);
  }
  if (account == null) {
    showSnackBar(context: context, message: context.t.localNotification.accountGone);
    return (step: LocalNoticeAccountStep.gone, top: null, action: null);
  }
  final result = await (switchTo ?? _switchLikeTheMenu)(context, account);
  if (result != SwitchAccountResult.switched || !context.mounted) {
    talker.info('notification of another account: not switched (${result.name}), notice page not opened');
    return (step: LocalNoticeAccountStep.notSwitched, top: null, action: null);
  }
  // The pages follow the new account by themselves; the lists of the notice page are rebuilt for it right away, so
  // the page never shows the previous account's notices under the new one.
  context.readOrNull<NotificationBloc>()?.add(NotificationReloadFromStorageRequested());
  final (:top, :action) = openNoticePageForTap(GoRouter.of(context), loggedIn: true, hasPopup: hasPopup());
  return (step: LocalNoticeAccountStep.switched, top: top, action: action);
}

/// Location of the page on top of [router], `null` before the first route matched.
///
/// Walks into shell routes, so a page inside the home shell reports its own location instead of the shell's, and a
/// page opened with `pushNamed` reports itself. Dialogs and bottom sheets are not routes of the router: the page
/// under them is reported, which is what a tap wants to know.
String? routerTopLocation(GoRouter router) => router.routerDelegate.currentConfiguration.lastOrNull?.matchedLocation;
