import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';

/// Status of the poll creation page.
enum PollCreateStatus {
  /// Fetching the form.
  loading,

  /// Network failure; retry with GET only.
  loadFailed,

  /// The page was served as guest; sign in to the same account and retry.
  loginRequired,

  /// The forum refused to offer the form, see [PollCreateState.message].
  denied,

  /// The form is not understood; continue in the browser.
  unsupported,

  /// Account changed; everything private was dropped.
  identityChanged,

  /// Filling in.
  editing,

  /// Final confirmation of [PollCreateState.submission].
  reviewing,

  /// Fetching a fresh form before the POST; nothing has been sent.
  checking,

  /// The fresh form check stopped before posting, see [PollCreateState.preflight]; input kept, nothing sent.
  preflightFailed,

  /// The single POST is in flight.
  submitting,

  /// The forum explicitly refused; input kept and may be sent again.
  rejected,

  /// The result is unknown; sending again is blocked until the user resolves it.
  unconfirmed,

  /// The poll thread is verified visible.
  published,

  /// The poll thread awaits moderation.
  moderated
  ;

  /// Whether the form inputs are shown.
  bool get showsInput => this == editing || this == rejected || this == preflightFailed;
}

/// Ephemeral state; never stored.
final class PollCreateState {
  /// Constructor.
  const PollCreateState({
    this.status = PollCreateStatus.loading,
    this.form,
    this.submission,
    this.message,
    this.tid,
    this.preflight,
    this.interruptedSubmit = false,
  });

  /// Status.
  final PollCreateStatus status;

  /// Validated form of the owning account.
  final PollCreateForm? form;

  /// The exact poll under confirmation or in flight.
  final PollSubmission? submission;

  /// Plain server message.
  final String? message;

  /// New thread id when known.
  final String? tid;

  /// Why the fresh form check stopped, when [status] is [PollCreateStatus.preflightFailed].
  final PollPreflightKind? preflight;

  /// A POST of this session may have reached the forum before the account changed: its result is unknown.
  ///
  /// Sticky for the session, so later account events keep the warning.
  final bool interruptedSubmit;
}

/// Loads one form, confirms one exact submission and posts it at most once per explicit confirmation.
///
/// Before the POST a fresh form of the same account and forum is fetched and the confirmed poll is checked against
/// it. The session ends when the page leaves ([endSession], the route predicate) or the account changes.
final class PollCreateCubit extends Cubit<PollCreateState> {
  /// Constructor.
  PollCreateCubit({
    required PollCreateRepository repository,
    required this.fid,
    Stream<AuthStatus>? authChanges,
    bool Function()? isActive,
  }) : _repo = repository,
       _isActive = isActive ?? _alwaysActive,
       super(const PollCreateState()) {
    _authSubscription = authChanges?.listen((status) {
      if (status is AuthStatusAuthed && _repo.belongsTo(status.userInfo.uid)) return;
      if ((status is AuthStatusLoading || status is AuthStatusUnknown) && _repo.ownerActive) return;
      // Still runs after the page left, so private input is erased during its exit animation too.
      _dropIdentity();
    });
  }

  static bool _alwaysActive() => true;

  /// Forum id.
  final String fid;

  final PollCreateRepository _repo;
  final bool Function() _isActive;
  StreamSubscription<AuthStatus>? _authSubscription;
  int _generation = 0;
  int? _busyGeneration;
  bool _ended = false;

  /// A POST handed to the transport has no delivered result yet.
  bool _postPending = false;

  /// Sticky: an account change happened while a sent POST had no known result.
  bool _interrupted = false;

  bool get _busy => _busyGeneration != null;

  /// Only the confirmation that started the busy phase may end it; a cancelled check must not.
  void _release(int generation) {
    if (_busyGeneration == generation) _busyGeneration = null;
  }

  /// Whether the session still accepts operations from its page.
  bool get _open {
    if (isClosed || _ended) return false;
    if (_isActive()) return true;
    endSession();
    return false;
  }

  /// Whether the confirmed poll can be sent now.
  bool get canConfirm =>
      _open && _repo.isCurrent && !_busy && state.status == PollCreateStatus.reviewing && state.submission != null;

  /// A mode switch must still belong to this session, even before the auth stream delivers an account change.
  bool get canSwitchMode => _open && _repo.isCurrent && !_busy;

  /// The page was popped, replaced or removed: invalidate pending work and callbacks synchronously.
  ///
  /// A request already sent is not cancelled; account changes still erase private state until [close].
  void endSession() {
    if (_ended) return;
    _ended = true;
    _generation++;
    _repo.end();
  }

  void _emitIfOpen(PollCreateState state) {
    if (!isClosed) emit(state);
  }

  void _dropIdentity() {
    if (_postPending) _interrupted = true;
    _repo.invalidate();
    _generation++;
    _emitIfOpen(PollCreateState(status: PollCreateStatus.identityChanged, interruptedSubmit: _interrupted));
  }

  bool _stillCurrent(int generation) {
    if (!_open || generation != _generation) return false;
    if (_repo.isCurrent) return true;
    if (!_repo.ownerActive) _dropIdentity();
    return false;
  }

  /// Fetch a fresh form; typed input lives in the page and is kept.
  Future<void> load() async {
    const reloadable = {
      PollCreateStatus.loading,
      PollCreateStatus.loadFailed,
      PollCreateStatus.loginRequired,
      PollCreateStatus.denied,
      PollCreateStatus.unsupported,
      PollCreateStatus.editing,
      PollCreateStatus.preflightFailed,
      PollCreateStatus.rejected,
    };
    if (_busy || !reloadable.contains(state.status)) return;
    final generation = ++_generation;
    if (!_stillCurrent(generation)) return;
    emit(const PollCreateState());
    final result = await _repo.fetchForm(fid);
    if (!_stillCurrent(generation)) return;
    if (result.kind == PollFormLoadKind.identityChanged) {
      _dropIdentity();
      return;
    }
    emit(switch (result.kind) {
      PollFormLoadKind.ready => PollCreateState(status: PollCreateStatus.editing, form: result.form),
      PollFormLoadKind.denied => PollCreateState(status: PollCreateStatus.denied, message: result.message),
      PollFormLoadKind.unsupported => const PollCreateState(status: PollCreateStatus.unsupported),
      PollFormLoadKind.loginRequired => const PollCreateState(status: PollCreateStatus.loginRequired),
      PollFormLoadKind.failed || PollFormLoadKind.identityChanged => const PollCreateState(
        status: PollCreateStatus.loadFailed,
      ),
    });
  }

  /// Validate [draft]; when valid, show its exact confirmation. No request is made.
  PollValidation? review(PollDraft draft) {
    final form = state.form;
    if (!_open || !state.status.showsInput || form == null || _busy || !_repo.isCurrent) return null;
    final validation = validatePollDraft(draft, form);
    if (validation.isValid) {
      emit(PollCreateState(status: PollCreateStatus.reviewing, form: form, submission: validation.submission));
    }
    return validation;
  }

  /// Cancel the confirmation, or the fresh form check still before the POST, without sending anything.
  void cancelReview() {
    if (!_open) return;
    if (state.status == PollCreateStatus.checking) {
      // The pending check's generation no longer matches, so it can never reach the POST.
      _generation++;
      _busyGeneration = null;
    } else if (state.status != PollCreateStatus.reviewing || _busy) {
      return;
    }
    emit(PollCreateState(status: PollCreateStatus.editing, form: state.form));
  }

  /// Check a fresh form, then POST the confirmed submission once; unknown results never send again.
  Future<void> confirm() async {
    if (!canConfirm) return;
    final form = state.form!;
    final submission = state.submission!;
    final generation = _generation;
    _busyGeneration = generation;
    emit(PollCreateState(status: PollCreateStatus.checking, form: form, submission: submission));

    PollPreflight preflight;
    try {
      preflight = await _repo.preflight(form, submission);
    } on Object {
      preflight = const PollPreflight(PollPreflightKind.failed);
    }
    // Final gate immediately before the one POST: page, session, account and operation generation.
    if (!_stillCurrent(generation)) {
      _release(generation);
      return;
    }
    if (preflight.kind == PollPreflightKind.identityChanged) {
      _release(generation);
      _dropIdentity();
      return;
    }
    if (preflight.kind != PollPreflightKind.ready) {
      _release(generation);
      emit(
        PollCreateState(
          status: PollCreateStatus.preflightFailed,
          form: preflight.form ?? form,
          message: preflight.message,
          preflight: preflight.kind,
        ),
      );
      return;
    }

    final fresh = preflight.form!;
    emit(PollCreateState(status: PollCreateStatus.submitting, form: fresh, submission: submission));
    PollCreateResult result;
    final dispatched = _repo.postsDispatched;
    try {
      final sending = _repo.submit(fresh, submission);
      _postPending = _repo.postsDispatched > dispatched;
      result = await sending;
    } on Object {
      // Never assume nothing was sent.
      result = const PollCreateResult(PollCreateOutcome.unconfirmed);
    }
    final sent = _repo.postsDispatched > dispatched;
    _postPending = false;
    _release(generation);
    if (isClosed || _ended || generation != _generation) return;
    if (!_repo.isCurrent || result.outcome == PollCreateOutcome.identityChanged) {
      if (sent && result.outcome != PollCreateOutcome.identityChanged) _interrupted = true;
      _dropIdentity();
      return;
    }
    emit(switch (result.outcome) {
      PollCreateOutcome.published => PollCreateState(status: PollCreateStatus.published, tid: result.tid),
      PollCreateOutcome.moderated => PollCreateState(status: PollCreateStatus.moderated, tid: result.tid),
      PollCreateOutcome.rejected => PollCreateState(
        status: PollCreateStatus.rejected,
        form: fresh,
        message: result.message,
      ),
      PollCreateOutcome.unconfirmed || PollCreateOutcome.identityChanged => PollCreateState(
        status: PollCreateStatus.unconfirmed,
        form: fresh,
        tid: result.tid,
      ),
    });
  }

  /// The user checked the forum and explicitly chose to edit again after an unknown result.
  void resolveUnconfirmed() {
    if (!_open || state.status != PollCreateStatus.unconfirmed || _busy || !_repo.isCurrent) return;
    emit(PollCreateState(status: PollCreateStatus.editing, form: state.form));
  }

  @override
  Future<void> close() async {
    // Invalidate synchronously before awaiting the subscription cleanup.
    endSession();
    await _authSubscription?.cancel();
    return super.close();
  }
}
