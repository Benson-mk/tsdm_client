import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/utils/new_thread_status.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// Result kind of [PollCreateRepository.fetchForm].
enum PollFormLoadKind {
  /// Supported form.
  ready,

  /// The forum answered with a message, e.g. no permission to create polls here.
  denied,

  /// Not understood: continue in the browser.
  unsupported,

  /// Served as guest: the same account must sign in again.
  loginRequired,

  /// Served to or requested by another account.
  identityChanged,

  /// Network or HTTP failure.
  failed,
}

/// Result of [PollCreateRepository.fetchForm].
final class PollFormLoad {
  /// Constructor.
  const PollFormLoad(this.kind, {this.form, this.message});

  /// Kind.
  final PollFormLoadKind kind;

  /// Form when ready.
  final PollCreateForm? form;

  /// Plain server message when denied.
  final String? message;
}

/// Result kind of [PollCreateRepository.preflight]; only [ready] may be followed by the POST.
enum PollPreflightKind {
  /// A fresh form still accepts the confirmed poll unchanged; post with its fields.
  ready,

  /// The fresh form's limits or offered settings changed the confirmed poll; review again.
  changed,

  /// The forum no longer offers the form, see [PollPreflight.message].
  denied,

  /// The fresh form is not understood; continue in the browser.
  unsupported,

  /// The fresh form was served as guest.
  loginRequired,

  /// Served to or requested by another account.
  identityChanged,

  /// Network or HTTP failure; nothing was posted and checking again is safe.
  failed,
}

/// Result of [PollCreateRepository.preflight].
final class PollPreflight {
  /// Constructor.
  const PollPreflight(this.kind, {this.form, this.message});

  /// Kind.
  final PollPreflightKind kind;

  /// Fresh form when [kind] is ready or changed.
  final PollCreateForm? form;

  /// Plain server message when denied.
  final String? message;
}

/// What is known after the single poll POST.
enum PollCreateOutcome {
  /// The thread is verified visible without status label.
  published,

  /// The forum says, or the header shows, that it awaits moderation.
  moderated,

  /// The forum explicitly refused; nothing was created.
  rejected,

  /// The request may have created a thread; do not send again automatically.
  unconfirmed,

  /// Nothing was sent because the account changed.
  identityChanged,
}

/// Result of [PollCreateRepository.submit].
final class PollCreateResult {
  /// Constructor.
  const PollCreateResult(this.outcome, {this.tid, this.message});

  /// Outcome.
  final PollCreateOutcome outcome;

  /// Thread id when known.
  final String? tid;

  /// Plain server message.
  final String? message;
}

/// Creates ordinary polls with one account-bound client for the page lifetime.
final class PollCreateRepository with LoggerMixin {
  /// Constructor.
  PollCreateRepository({required NetClientProvider client, required int? Function() currentUid})
    : this.withTransport(
        currentUid: currentUid,
        getPage: (url) => client.get(url).run(),
        sendForm: (url, body) => client.postForm(url, data: body, singleAttempt: true).run(),
      );

  /// Injectable transports; the submission is never retried.
  PollCreateRepository.withTransport({
    required int? Function() currentUid,
    required Future<SyncEither<Response<dynamic>>> Function(String) getPage,
    required Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) sendForm,
  }) : _get = getPage,
       _post = sendForm,
       _currentUid = currentUid,
       _ownerUid = currentUid();

  final Future<SyncEither<Response<dynamic>>> Function(String) _get;
  final Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) _post;
  final int? Function() _currentUid;
  final int? _ownerUid;
  bool _invalidated = false;
  bool _ended = false;
  int _postsDispatched = 0;

  /// Permanent: switching back to the account never revives this session.
  void invalidate() => _invalidated = true;

  /// The page left: no further request starts. A request already sent is not cancelled.
  void end() => _ended = true;

  /// Whether the owning account is still the active one, whether or not the page left.
  bool get ownerActive => !_invalidated && _ownerUid != null && _ownerUid > 0 && _ownerUid == _currentUid();

  /// Whether the session may still send requests for the active account.
  bool get isCurrent => !_ended && ownerActive;

  /// Ignore repeated verification events for the same active account.
  bool belongsTo(int? uid) => ownerActive && uid == _ownerUid;

  /// Number of poll POSTs handed to the transport by this session; a dispatched POST may have reached the forum.
  int get postsDispatched => _postsDispatched;

  /// Poll creation form url offered by the forum page.
  static String formUrl(String fid) => '$baseUrl/forum.php?mod=post&action=newthread&fid=$fid&special=1';

  /// Fetch and validate the poll form of [fid].
  Future<PollFormLoad> fetchForm(String fid) async {
    if (!isCurrent) return const PollFormLoad(PollFormLoadKind.identityChanged);
    final result = await _get(formUrl(fid));
    if (!isCurrent) return const PollFormLoad(PollFormLoadKind.identityChanged);
    final Response<dynamic> response;
    switch (result) {
      case Left():
        return const PollFormLoad(PollFormLoadKind.failed);
      case Right(:final value):
        response = value;
    }
    if (response.statusCode != 200 || response.data is! String) return const PollFormLoad(PollFormLoadKind.failed);
    final document = parseHtmlDocument(response.data as String);
    final served = parseLoggedUidFromDocument(document);
    if (served == null) return const PollFormLoad(PollFormLoadKind.loginRequired);
    if (served != _ownerUid) return const PollFormLoad(PollFormLoadKind.identityChanged);
    final parsed = PollCreateForm.parse(document, fid: fid, uid: served);
    return switch (parsed.kind) {
      PollFormParseKind.ready => PollFormLoad(PollFormLoadKind.ready, form: parsed.form),
      PollFormParseKind.denied => PollFormLoad(PollFormLoadKind.denied, message: parsed.message),
      PollFormParseKind.unsupported => const PollFormLoad(PollFormLoadKind.unsupported),
    };
  }

  /// GET a fresh form of the same forum and account and check that [submission] is still posted unchanged.
  ///
  /// Never posts; every non-ready result means nothing was sent.
  Future<PollPreflight> preflight(PollCreateForm confirmed, PollSubmission submission) async {
    if (confirmed.uid != _ownerUid) return const PollPreflight(PollPreflightKind.identityChanged);
    final load = await fetchForm(confirmed.fid);
    switch (load.kind) {
      case PollFormLoadKind.ready:
        final fresh = load.form!;
        if (fresh.uid != _ownerUid || fresh.fid != confirmed.fid) {
          return const PollPreflight(PollPreflightKind.identityChanged);
        }
        final fits = pollSubmissionFitsFreshForm(submission: submission, confirmed: confirmed, fresh: fresh);
        return PollPreflight(fits ? PollPreflightKind.ready : PollPreflightKind.changed, form: fresh);
      case PollFormLoadKind.denied:
        return PollPreflight(PollPreflightKind.denied, message: load.message);
      case PollFormLoadKind.unsupported:
        return const PollPreflight(PollPreflightKind.unsupported);
      case PollFormLoadKind.loginRequired:
        return const PollPreflight(PollPreflightKind.loginRequired);
      case PollFormLoadKind.identityChanged:
        return const PollPreflight(PollPreflightKind.identityChanged);
      case PollFormLoadKind.failed:
        return const PollPreflight(PollPreflightKind.failed);
    }
  }

  /// POST [submission] exactly once and classify the answer without ever resending.
  ///
  /// [form] must be the fresh form returned by [preflight]; the transport is invoked synchronously within this call.
  Future<PollCreateResult> submit(PollCreateForm form, PollSubmission submission) async {
    if (!isCurrent || form.uid != _ownerUid) return const PollCreateResult(PollCreateOutcome.identityChanged);
    _postsDispatched++;
    final result = await _post(form.actionUrl, submission.toPayload(form));

    final Response<dynamic> response;
    switch (result) {
      case Left(:final value) when value is HttpHandshakeFailedException && [301, 302, 303].contains(value.statusCode):
        return _verify(threadTidOf(value.headers?.value('location')));
      case Left():
        // The request may still have reached the forum.
        return const PollCreateResult(PollCreateOutcome.unconfirmed);
      case Right(:final value):
        response = value;
    }
    if ([301, 302, 303].contains(response.statusCode)) {
      return _verify(threadTidOf(response.headers.value('location')));
    }
    if (response.statusCode != 200 || response.data is! String) {
      return const PollCreateResult(PollCreateOutcome.unconfirmed);
    }

    final document = parseHtmlDocument(response.data as String);
    final message = document.querySelector('#messagetext');
    if (message != null) {
      final text = (message.querySelector('p') ?? message).innerText.trim();
      final tid = threadTidOf(message.querySelector('p.alert_btnleft a[href]')?.attributes['href']);
      // Upstream showmessage: `alert_right` = forward with a *_succeed message, `alert_error` = returnable
      // failure, `alert_info` = any other forward or note. Only an explicit error proves nothing was created.
      if (message.classes.contains('alert_error') && !message.classes.contains('alert_right')) {
        return PollCreateResult(PollCreateOutcome.rejected, message: text);
      }
      if (message.classes.contains('alert_right') && mentionsModeration(text)) {
        return PollCreateResult(PollCreateOutcome.moderated, tid: tid);
      }
      // Success, information or unknown class: verify a same-site thread link with a GET, never by posting again.
      return _verify(tid);
    }
    final canonical = threadTidOf(document.querySelector('head link[rel="canonical"]')?.attributes['href']);
    if (canonical != null && parseLoggedUidFromDocument(document) == _ownerUid) {
      return _classify(canonical, classifyNewThreadHeader(document, canonical));
    }
    return const PollCreateResult(PollCreateOutcome.unconfirmed);
  }

  /// GET the new thread as its author; a redirect or message link alone never proves publication.
  Future<PollCreateResult> _verify(String? tid) async {
    if (tid == null) return const PollCreateResult(PollCreateOutcome.unconfirmed);
    if (!isCurrent) return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
    final result = await _get('$baseUrl/forum.php?mod=viewthread&tid=$tid');
    if (!isCurrent) return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
    return result.match((_) => PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid), (response) {
      if (response.statusCode != 200 || response.data is! String) {
        return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
      }
      final document = parseHtmlDocument(response.data as String);
      if (parseLoggedUidFromDocument(document) != _ownerUid) {
        return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
      }
      return _classify(tid, classifyNewThreadHeader(document, tid));
    });
  }

  PollCreateResult _classify(String tid, NewThreadHeaderStatus status) => switch (status) {
    NewThreadHeaderStatus.visible => PollCreateResult(PollCreateOutcome.published, tid: tid),
    NewThreadHeaderStatus.moderating => PollCreateResult(PollCreateOutcome.moderated, tid: tid),
    NewThreadHeaderStatus.draft || NewThreadHeaderStatus.unknown => PollCreateResult(
      PollCreateOutcome.unconfirmed,
      tid: tid,
    ),
  };
}
