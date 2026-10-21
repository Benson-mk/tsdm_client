/// All local notification events and types.
class LocalNoticeKeys {
  LocalNoticeKeys._();

  /// Open notification page.
  ///
  /// Tab in the page is not specified. The payload of every notification while only the account in use is announced
  /// (and of the test notification of the settings page): the page of the account in use.
  static const openNotification = 'openNotification';

  /// Payload of a notification about account [uid] while every logged-in account is announced
  /// (`SettingsKeys.backgroundSyncAllAccounts`): its notice page, as that account.
  ///
  /// A tap on it switches to [uid] first when another account is in use (see `openNoticePageOfAccount`).
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
