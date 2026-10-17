import 'dart:async';

/// Tells that an account sent a private message from the app (the chat page, the chat history page or the share to
/// a friend), so its stored conversation list is refreshed once (GitHub #193).
///
/// The polls ask the forum's app API first and skip the private message page when no unread conversation was
/// received; a conversation the user wrote to last never made them fetch it, and so never showed in the list.
/// `NotificationBloc` listens and refreshes the list without that question, once for a burst of messages, and only
/// while the account that sent is still the current one.
abstract final class PersonalMessageSent {
  static final _controller = StreamController<int?>.broadcast();

  /// Uid of the account that sent a private message, null when not known.
  static Stream<int?> get stream => _controller.stream;

  /// Report a private message the forum accepted from account [uid] (null when not known: nothing is refreshed).
  static void notify(int? uid) => _controller.add(uid);
}
