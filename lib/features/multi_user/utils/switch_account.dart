import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// How a [switchAccount] call ended.
enum SwitchAccountResult {
  /// The requested account is the one in use now.
  switched,

  /// The forum did not accept the login saved for the account, or could not be asked: the account in use is kept.
  failed,

  /// The in-app notification sync kept fetching for too long: nothing was tried.
  syncBusy,

  /// Another switch was still running: this request was ignored.
  alreadySwitching,

  /// The page holding the [SwitchUserBloc] went away before the switch ended; the switch itself may still finish.
  abandoned,
}

/// Reason of the pause held on [AutoNotificationCubit] while switching.
const _lockReason = 'switch user';

/// Tries and gap between them when waiting for an in-app notification fetch in flight, about 3 seconds in all.
const _lockRetries = 10;
const _lockRetryGap = Duration(milliseconds: 300);

/// Whether a switch is running, whichever page started it.
bool _switching = false;

/// Whether an account switch is running right now, from the manage accounts page or the avatar menu.
bool get isSwitchingAccount => _switching;

/// Switch to the saved account [userInfo] through [bloc] and tell the user how it went.
///
/// The one way accounts are switched, shared by the manage accounts page and the avatar menu (GitHub #184 follow-up)
/// so both behave the same:
///
/// * Only one switch runs at a time: a tap while one is running returns [SwitchAccountResult.alreadySwitching].
/// * The in-app notification sync is paused first, waiting a moment for a fetch in flight: the fetch reads the
///   current account when it starts and would store what the forum answered for the previous one. When it is still
///   fetching after about 3 seconds nothing is tried and a toast says so (it used to give up without a word).
/// * The sync is resumed in a `finally`, whatever happens. It used to be resumed by a listener of the manage accounts
///   page: leaving the page while switching closed the bloc before the result came, and the sync stayed paused
///   until the app restarted.
/// * A toast tells the result while [context] is still mounted; the caller closes its dialog on
///   [SwitchAccountResult.switched] and keeps it open otherwise, so the user can try again or log in again.
Future<SwitchAccountResult> switchAccount(
  BuildContext context, {
  required SwitchUserBloc bloc,
  required UserLoginInfo userInfo,
}) async {
  if (_switching) {
    talker.debug('switch account: another switch is running, ignored');
    return SwitchAccountResult.alreadySwitching;
  }
  _switching = true;
  // App wide, outlives the dialog; missing only in tests that do not provide it.
  final auto = context.readOrNull<AutoNotificationCubit>();
  final tr = context.t;
  try {
    final (result, reason) = await _run(auto, bloc, userInfo);
    if (!context.mounted) {
      return result;
    }
    final message = switch (result) {
      SwitchAccountResult.switched => tr.currentAccount.switched(username: userInfo.username ?? ''),
      SwitchAccountResult.failed => switch (reason) {
        SwitchUserNotAuthedException() => tr.loginPage.perhapsExpired,
        _ => tr.general.failedToLoad,
      },
      SwitchAccountResult.syncBusy => tr.currentAccount.switchBusy,
      SwitchAccountResult.alreadySwitching || SwitchAccountResult.abandoned => null,
    };
    if (message != null) {
      showSnackBar(context: context, message: message);
    }
    return result;
  } finally {
    _switching = false;
  }
}

Future<(SwitchAccountResult, AppException?)> _run(
  AutoNotificationCubit? auto,
  SwitchUserBloc bloc,
  UserLoginInfo userInfo,
) async {
  try {
    if (!await _pauseAutoSync(auto)) {
      talker.warning('switch account: in-app notification sync still fetching, not switching');
      return (SwitchAccountResult.syncBusy, null);
    }
    if (bloc.isClosed) {
      return (SwitchAccountResult.abandoned, null);
    }
    // Listen before adding the event so the result cannot be missed. The stream ends without a result when the bloc
    // is closed with its page meanwhile.
    final done = bloc.stream.firstWhere(
      (e) => e is SwitchUserSuccess || e is SwitchUserFailure,
      orElse: () => const SwitchUserInitial(),
    );
    bloc.add(SwitchUserStartRequested(userInfo));
    switch (await done) {
      case SwitchUserSuccess():
        return (SwitchAccountResult.switched, null);
      case SwitchUserFailure(:final reason):
        return (SwitchAccountResult.failed, reason);
      case SwitchUserInitial() || SwitchUserLoading():
        talker.warning('switch account: the page went away before the switch ended');
        return (SwitchAccountResult.abandoned, null);
    }
  } finally {
    // Also after a timeout: nothing was recorded then and the resume changes nothing.
    auto?.resume(_lockReason);
  }
}

/// Pause the in-app notification sync, waiting for a fetch in flight like the sync of all accounts does.
///
/// False when it was still fetching after [_lockRetries] tries; the pause is only recorded once it is taken.
Future<bool> _pauseAutoSync(AutoNotificationCubit? auto) async {
  if (auto == null) {
    return true;
  }
  var times = _lockRetries;
  while (auto.pause(_lockReason)) {
    times -= 1;
    if (times <= 0) {
      return false;
    }
    talker.info('switch account is waiting for the auto sync lock... $times');
    await Future<void>.delayed(_lockRetryGap);
  }
  return true;
}
