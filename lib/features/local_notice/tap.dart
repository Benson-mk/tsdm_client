import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

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

/// Location of the page on top of [router], `null` before the first route matched.
///
/// Walks into shell routes, so a page inside the home shell reports its own location instead of the shell's, and a
/// page opened with `pushNamed` reports itself. Dialogs and bottom sheets are not routes of the router: the page
/// under them is reported, which is what a tap wants to know.
String? routerTopLocation(GoRouter router) => router.routerDelegate.currentConfiguration.lastOrNull?.matchedLocation;
