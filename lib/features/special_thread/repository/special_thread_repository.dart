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

/// The outcome of the forum's answer [data] to an action, from the result of its app API (plugin 2.6.0,
/// [tsdmAppWriteResultOf]): a `handle`, `message` or `redirect` the forum calls a success (`ok` 1, not the login
/// prompt: the poll's `thread_poll_succeed` redirect, the activity's `activity_completion` handler and
/// `activity_cancel_success` page, the bounty's `reward_completion` note, the debate's `debate_poll_succeed`) is done,
/// with the forum's message; any other is refused with [TsdmAppWriteResult.reason] (`reward_cant_operate`, the login
/// prompt…). A `page` (the forum printed something else) and an answer without a result tell nothing.
SpecialActionOutcome specialActionOutcomeOf(Object? data) {
  final result = tsdmAppWriteResultOf(data);
  if (result == null || result.kind == TsdmAppWriteKind.page) {
    return const SpecialActionUnknown();
  }
  if (result.succeeded) {
    return SpecialActionDone(result.message);
  }
  return SpecialActionRefused(result.reason.isEmpty ? t.specialThread.refused : result.reason);
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
        SpecialRequestMethod.get => client.get(withTsdmAppJsonWrite(request.url)),
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
    return specialActionOutcomeOf(data);
  }
}
