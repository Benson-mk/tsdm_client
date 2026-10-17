import 'dart:async';

/// Tells that the current account sent a private message from the app (the chat page, the chat history page or the
/// share to a friend), so the stored conversation list is refreshed once (GitHub #193).
///
/// The polls ask the forum's app API first and skip the private message page when no unread conversation was
/// received; a conversation the user wrote to last never made them fetch it, and so never showed in the list.
/// `NotificationBloc` listens and refreshes the list without that question, once for a burst of messages.
abstract final class PersonalMessageSent {
  static final _controller = StreamController<void>.broadcast();

  /// A private message was sent.
  static Stream<void> get stream => _controller.stream;

  /// Report a private message the forum accepted.
  static void notify() => _controller.add(null);
}
