import 'dart:convert';

import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The last message of a conversation the user deleted from the app's list: its time (seconds) and text.
typedef DeletedConversation = ({int timestamp, String data});

/// Name of the settings row holding the conversations account [uid] deleted from the app's list.
///
/// One JSON object per account, peer uid to the deleted last message: `{"<peer>": {"t": <seconds>, "d": "<text>"}}`.
String deletedPersonalMessagesKey(int uid) => 'deletedPersonalMessages.$uid';

/// The conversations account [uid] deleted from the app's list, by peer uid. Unreadable rows and entries are
/// ignored: the conversation then shows again, as it did before deletions were remembered.
Future<Map<int, DeletedConversation>> deletedPersonalMessagesOf(StorageProvider storage, int uid) async {
  final String? raw;
  try {
    raw = await storage.getString(deletedPersonalMessagesKey(uid));
  } on Object catch (_) {
    return {};
  }
  if (raw == null) {
    return {};
  }
  try {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      return {};
    }
    return {
      for (final MapEntry(:key, :value) in json.entries)
        if ((int.tryParse(key), value) case (final int peer, {'t': final int t, 'd': final String d}))
          peer: (
            timestamp: t,
            data: d,
          ),
    };
  } on FormatException {
    return {};
  }
}

Future<void> _save(StorageProvider storage, int uid, Map<int, DeletedConversation> deleted) async {
  if (deleted.isEmpty) {
    await storage.deleteKey(deletedPersonalMessagesKey(uid));
    return;
  }
  await storage.saveString(
    deletedPersonalMessagesKey(uid),
    jsonEncode({
      for (final MapEntry(:key, :value) in deleted.entries) '$key': {'t': value.timestamp, 'd': value.data},
    }),
  );
}

/// Whether [message] is the conversation [deleted] removed, or an older copy of it: the same last message, or an
/// earlier one. A newer message of the peer (or of the user) brings the conversation back.
bool isDeletedConversationCopy(PersonalMessageV2 message, DeletedConversation? deleted) =>
    deleted != null &&
    (message.timestamp < deleted.timestamp || (message.timestamp == deleted.timestamp && message.data == deleted.data));

/// Delete the conversation of account [uid] with [peerUid] from storage and remember its last message, so a later
/// fetch of the same conversation does not store it again (GitHub #193 review).
///
/// The delete is local only: the forum keeps the conversation, and every refresh that lists the private message page
/// (the pull-to-refresh, the one after sending a private message) brought it back, unread again when the peer wrote
/// last. The stored row gives the time and text remembered; [shown], the copy on screen, is used when it is newer or
/// nothing is stored.
///
/// Runs under [StorageProvider.exclusively], like the sync that reads the record ([dropDeletedConversations]).
Future<void> deletePersonalMessageRemembered({
  required StorageProvider storage,
  required int uid,
  required int peerUid,
  PersonalMessageV2? shown,
}) => storage.exclusively(() async {
  final stored = (await storage.fetchNotificationSince(uid: uid, timestamp: 0).run()).personalMessageList
      .where((e) => e.peerUid == peerUid)
      .map((e) => (timestamp: e.timestamp, data: e.data));
  final candidates = [...stored, if (shown != null) (timestamp: shown.timestamp, data: shown.data)];
  if (candidates.isNotEmpty) {
    final latest = candidates.reduce((a, b) => b.timestamp > a.timestamp ? b : a);
    final deleted = await deletedPersonalMessagesOf(storage, uid);
    final previous = deleted[peerUid];
    if (previous == null || latest.timestamp >= previous.timestamp) {
      deleted[peerUid] = latest;
      await _save(storage, uid, deleted);
    }
  }
  await storage.deletePersonalMessage(uid: uid, peerUid: peerUid).run();
});

/// [fetched] without the conversations account [uid] deleted from the app's list ([deletePersonalMessageRemembered])
/// that did not change since: they are neither stored nor news. A conversation with a newer message is kept and its
/// record dropped.
///
/// Call it inside [StorageProvider.exclusively].
Future<NotificationV2> dropDeletedConversations({
  required StorageProvider storage,
  required int uid,
  required NotificationV2 fetched,
}) async {
  if (fetched.personalMessageList.isEmpty) {
    return fetched;
  }
  final deleted = await deletedPersonalMessagesOf(storage, uid);
  if (deleted.isEmpty) {
    return fetched;
  }
  final kept = fetched.personalMessageList.where((m) => !isDeletedConversationCopy(m, deleted[m.peerUid])).toList();
  final back = kept.map((m) => m.peerUid).where(deleted.containsKey).toSet();
  if (back.isNotEmpty) {
    deleted.removeWhere((peer, _) => back.contains(peer));
    await _save(storage, uid, deleted);
  }
  return fetched.copyWith(personalMessageList: kept);
}
