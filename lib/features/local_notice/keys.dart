/// All local notification events and types.
class LocalNoticeKeys {
  LocalNoticeKeys._();

  /// Open notification page.
  ///
  /// Tab in the page is not specified. The payload of a notification posted before it named its account, and of the
  /// test notification of the settings page: the page of the account in use.
  static const openNotification = 'openNotification';

  /// Payload of a notification about account [uid]: its notice page, as that account.
  ///
  /// A tap on it switches to [uid] first when another account is in use (see `openNoticePageOfAccount`): the
  /// background message service announces every saved account when asked to, and the account in use may have changed
  /// since any notification was posted.
  static String openNotificationOf(int uid) => '$openNotification:$uid';

  /// Whether [payload] opens the notice page, and as which account: `(uid: null)` for [openNotification] (the account
  /// in use), `(uid: n)` for [openNotificationOf], null for anything else.
  static ({int? uid})? parseOpenNotification(String? payload) {
    if (payload == openNotification) {
      return (uid: null);
    }
    const prefix = '$openNotification:';
    if (payload == null || !payload.startsWith(prefix)) {
      return null;
    }
    final uid = int.tryParse(payload.substring(prefix.length));
    if (uid == null || uid <= 0) {
      return null;
    }
    return (uid: uid);
  }
}
