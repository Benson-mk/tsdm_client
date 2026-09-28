part of 'checkin_bloc.dart';

/// Event of checkin.
@MappableClass()
sealed class CheckinEvent with CheckinEventMappable {
  /// Constructor.
  const CheckinEvent();
}

/// User required to checkin.
@MappableClass()
final class CheckinRequested extends CheckinEvent with CheckinRequestedMappable {
  /// Constructor.
  const CheckinRequested() : super();
}

/// Auth status changed.
///
/// Triggered by [CheckinBloc].
///
/// Passive event.
@MappableClass()
final class CheckinAuthChanged extends CheckinEvent with CheckinAuthChangedMappable {
  /// Constructor.
  const CheckinAuthChanged({required this.authed}) : super();

  /// Latest auth status.
  final bool authed;
}

/// Ask whether the current account already checked in today, from the record of this app.
///
/// Sent when a page showing the check-in state opens or reloads; the answer is [CheckinStateChecked] or the initial
/// state, a running check-in is left alone.
@MappableClass()
final class CheckinStatusRequested extends CheckinEvent with CheckinStatusRequestedMappable {
  /// Constructor.
  const CheckinStatusRequested() : super();
}
