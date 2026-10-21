import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What the forum answered an action of a special block ([SpecialRequest]).
sealed class SpecialActionOutcome {
  const SpecialActionOutcome();
}

/// The forum did it; [message] is its message (empty when it gave none: a redirect).
final class SpecialActionDone extends SpecialActionOutcome {
  /// Constructor.
  const SpecialActionDone(this.message);

  /// The forum's message.
  final String message;
}

/// The forum refused; [message] says why (the forum's words, or the app's when the forum gave none).
final class SpecialActionRefused extends SpecialActionOutcome {
  /// Constructor.
  const SpecialActionRefused(this.message);

  /// Why.
  final String message;
}

/// No verdict: the request failed, or the forum answered something that is not a result of its app API. The action
/// may have been done all the same: only reading the page again tells.
final class SpecialActionUnknown extends SpecialActionOutcome {
  /// Constructor.
  const SpecialActionUnknown();
}

/// The outcome of the forum's answer [data] to an action ([specialOutcomeOfResult]); a `page` (the forum printed
/// something else) and an answer without a result of the forum's app API (plugin 2.6.0, [tsdmAppWriteResultOf]) tell
/// nothing.
SpecialActionOutcome specialActionOutcomeOf(
  Object? data, {
  required Set<String> doneKeys,
  Set<String> alreadyKeys = const {},
}) {
  final result = tsdmAppWriteResultOf(data);
  if (result == null || result.kind == TsdmAppWriteKind.page) {
    return const SpecialActionUnknown();
  }
  return specialOutcomeOfResult(result, doneKeys: doneKeys, alreadyKeys: alreadyKeys);
}

/// The outcome of the forum's [result] (a `handle`, `message` or `redirect`) of an action done with one of the
/// language keys [doneKeys] (the poll's `thread_poll_succeed`, the activity's `activity_completion` and
/// `activity_cancel_success`, the bounty's `reward_completion`, the debate's `debate_poll_succeed`).
///
/// Refused when the forum says so (not `ok`, or the login prompt), with [TsdmAppWriteResult.reason]. Done when it
/// answered one of [doneKeys], showed its message as a success (`alert` right), or went on without a message (a
/// redirect). The forum also goes on to the thread with some refusals (`debate_poll_voted`, `debate_poll_myself`:
/// the AJAX success hook with a link, `alert` info), which the plugin passes as `ok` 1: another key is refused with
/// the forum's message. Plain text without a key tells nothing.
///
/// A key of [alreadyKeys] (`debate_poll_voted`) is done as well, with the forum's words: the action was done before,
/// by a request the transport sent twice or from a page read before it; the page read again shows it.
SpecialActionOutcome specialOutcomeOfResult(
  TsdmAppWriteResult result, {
  required Set<String> doneKeys,
  Set<String> alreadyKeys = const {},
}) {
  final refused = SpecialActionRefused(result.reason.isEmpty ? t.specialThread.refused : result.reason);
  if (alreadyKeys.contains(result.messageKey) && !result.login) {
    return SpecialActionDone(result.message.isEmpty ? t.specialThread.already : result.message);
  }
  if (!result.succeeded) {
    return refused;
  }
  final key = result.messageKey;
  if (doneKeys.contains(key) ||
      result.alert == 'right' ||
      (key.isEmpty && result.message.isEmpty && result.kind == TsdmAppWriteKind.redirect)) {
    return SpecialActionDone(result.message);
  }
  return key.isEmpty ? const SpecialActionUnknown() : refused;
}

/// Sends the actions of the special blocks of a thread (plugin 2.8.0): the forms the forum's own page sends, with the
/// result parameter of the forum's app API ([withTsdmAppJsonWrite]), once (no automatic retry of a write).
final class SpecialThreadRepository {
  /// Constructor; [send] is the transport (tests inject their own).
  const SpecialThreadRepository({required this.send});

  /// The app's client: a POST through [NetClientProvider.postForm] (which adds the result parameter), a GET with it
  /// added; the AJAX header follows `inajax=1` as for every request.
  factory SpecialThreadRepository.network(NetClientProvider client) => SpecialThreadRepository(
    send: (request) async {
      final call = switch (request.method) {
        SpecialRequestMethod.post => client.postForm(request.url, data: request.fields, singleAttempt: true),
        // A write all the same: sent once, never replayed by the transport.
        SpecialRequestMethod.get => client.get(withTsdmAppJsonWrite(request.url), singleAttempt: true),
      };
      return switch (await call.run()) {
        Right(:final value) => value.data,
        Left(:final value) => throw value,
      };
    },
  );

  /// Send a request, return the forum's answer; throws when the request failed.
  final Future<Object?> Function(SpecialRequest request) send;

  /// Send [request] and tell what the forum answered.
  Future<SpecialActionOutcome> submit(SpecialRequest request) async {
    final Object? data;
    try {
      data = await send(request);
    } on Exception catch (e) {
      talker.warning('special thread action failed: $request: $e');
      return const SpecialActionUnknown();
    }
    return specialActionOutcomeOf(data, doneKeys: request.doneKeys, alreadyKeys: request.alreadyKeys);
  }
}
