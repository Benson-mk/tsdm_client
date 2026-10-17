part of 'models.dart';

/// Base state of [NotificationV2] state.
@MappableClass()
sealed class NotificationInfoState with NotificationInfoStateMappable {
  /// Constructor.
  const NotificationInfoState();
}

/// Fetching notification.
@MappableClass()
final class NotificationInfoStateLoading extends NotificationInfoState with NotificationInfoStateLoadingMappable {
  /// Constructor.
  const NotificationInfoStateLoading();
}

/// Fetched notice successfully.
@MappableClass()
final class NotificationInfoStateSuccess extends NotificationInfoState with NotificationInfoStateSuccessMappable {
  /// Constructor.
  const NotificationInfoStateSuccess(this.uid, this.info, {this.since, this.window});

  /// User id of whom the fetch action on.
  final int uid;

  /// Fetched info.
  final NotificationV2 info;

  /// The inclusive lower bound (seconds) this fetch was asked for, null when this device had none stored yet.
  ///
  /// A notice fetched for the first time inside that window is news to this device whatever read flag the server
  /// rendered, see `reconcileNoticeReadState` (GitHub #79).
  final int? since;

  /// The lower bound (seconds) the fetch actually used, [since] clamped to the last three days; null when not known.
  ///
  /// Only a conversation not older than it is news (GitHub #193 review): the raw [since] is null on the first fetch
  /// and may lie days ahead when the device clock was fast (GitHub #71).
  final int? window;
}

/// Failed to fetch notification.
@MappableClass()
final class NotificationInfoStateFailure extends NotificationInfoState with NotificationInfoStateFailureMappable {
  /// Constructor.
  const NotificationInfoStateFailure();
}
