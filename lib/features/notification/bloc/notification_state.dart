part of 'notification_bloc.dart';

/// Status of notification.
enum NotificationStatus {
  /// Initial.
  initial,

  /// Loading.
  loading,

  /// Success.
  success,

  /// Failure.
  failure,
}

/// State of notification.
@MappableClass()
class NotificationState with NotificationStateMappable {
  /// Constructor.
  const NotificationState({
    this.status = NotificationStatus.initial,
    this.noticeList = const [],
    this.personalMessageList = const [],
    this.broadcastMessageList = const [],
    this.latestTime,
    this.ownerUid,
  });

  /// Notice tab status.
  final NotificationStatus status;

  /// All fetched [NoticeV2].
  final List<NoticeV2> noticeList;

  /// All fetched [PersonalMessageV2].
  final List<PersonalMessageV2> personalMessageList;

  /// All fetched [BroadcastMessageV2].
  final List<BroadcastMessageV2> broadcastMessageList;

  /// The lower bound of the next fetch, recorded after a successful one.
  ///
  /// From the forum's clock of the fetch (`nextFetchBound`), as the auto sync records it; the time of the newest
  /// notification fetched only when the forum did not tell its clock.
  final DateTime? latestTime;

  /// The account the lists are of: set by every fetch and every reload from storage, null before the first and after
  /// a reset.
  ///
  /// The notice page shows nothing of another account than the one in use (an account switch, before the lists of
  /// the new account are in), and a tap on another account's notification opens the page once the lists are the new
  /// account's (`openNoticePageOfAccount`).
  final int? ownerUid;
}
