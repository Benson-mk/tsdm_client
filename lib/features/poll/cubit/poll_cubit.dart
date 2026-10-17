import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:universal_html/parsing.dart';

/// Ephemeral poll UI state; never saved to disk.
final class PollState {
  /// Constructor.
  const PollState({
    this.poll,
    this.uid,
    this.busy = false,
    this.failed = false,
    this.submissionUnconfirmed = false,
    this.choices = const {},
  });

  /// Latest server snapshot.
  final ForumPoll? poll;

  /// Account the snapshot belongs to.
  final int? uid;

  /// A load or submission is in progress.
  final bool busy;

  /// Loading failed; only a GET retry is available.
  final bool failed;

  /// The refreshed server state did not confirm the submission.
  final bool submissionUnconfirmed;

  /// Explicitly selected option identifiers.
  final Set<String> choices;
}

/// Serializes voting and discards completions from obsolete accounts/pages.
class PollCubit extends Cubit<PollState> {
  /// Constructor.
  PollCubit({required this.url, required this.currentUid, required this.repository}) : super(const PollState());

  /// Original post URL, resolved by the forum to its thread.
  final String url;

  /// Active account, rechecked around every asynchronous operation.
  final int? Function() currentUid;

  /// Creates an identity-bound transport for each new fetch.
  final PollRepository Function() repository;
  int _generation = 0;
  PollRepository? _loadedRepository;

  /// The polls a vote was sent for since the app started, as (account, [url]); in memory only.
  ///
  /// A vote is final, and a page read before it still shows the poll open: the floors a failed reload of the thread
  /// page puts back on screen (see ThreadBloc) build their cards again from that page, which showed the poll open for
  /// a second vote the forum refuses. Recorded when the vote is sent: the forum may count it although its answer never
  /// arrives (a failed request, or the card closed meanwhile).
  static final _votesSent = <(int, String)>{};

  /// Forget the votes sent, for tests.
  @visibleForTesting
  static void forgetVotesSent() => _votesSent.clear();

  /// Hide old-account data immediately, including during a login transition.
  void invalidate() {
    _generation++;
    _loadedRepository = null;
    emit(const PollState(busy: true));
  }

  bool _current(int generation, int? uid) => !isClosed && generation == _generation && uid == currentUid();

  /// Show the poll [form] of the page the post was read from, a page served to [servedUid], without asking the forum:
  /// the thread page already loaded it for the account in use.
  ///
  /// False when it cannot be shown, the caller then loads instead:
  ///
  /// * The page belongs to another account than the current one (the account changed since).
  /// * The page was served as to a guest, or does not say to whom, while an account is in use. The forum does that when
  ///   the session of the account expired (issue #25), and the account may have logged in again since; or the page was
  ///   read before a login: the floors a failed reload of the thread page puts back after a login or a switch are
  ///   those of the page before (see ThreadBloc). Shown, the card asked an account logged in to log in, and asked the
  ///   forum nothing. Only such a page costs a request, mostly while the session is expired; a guest gets the page of
  ///   a guest.
  /// * The page shows the poll open although this account sent a vote for it since (the page was read before the vote,
  ///   see [_votesSent]).
  ///
  /// The form is checked the way [PollRepository.fetch] checks a page.
  bool adopt(String form, {required int? servedUid}) {
    final uid = currentUid();
    if (servedUid == null && uid != null) {
      return false;
    }
    final ForumPoll poll;
    try {
      poll = PollRepository.pollOfPage(parseHtmlDocument(form), servedUid: servedUid, uid: uid);
    } on FormatException {
      return false;
    }
    if (poll.availability == PollAvailability.available && uid != null && _votesSent.contains((uid, url))) {
      return false;
    }
    _generation++;
    // Votes go out through a client bound to the account the form belongs to, as after a load.
    _loadedRepository = repository();
    emit(PollState(poll: poll, uid: uid));
    return true;
  }

  /// Reload by GET only. Never repeat a failed/ambiguous submission here.
  Future<void> load() async {
    final generation = ++_generation;
    final uid = currentUid();
    final repo = repository();
    _loadedRepository = null;
    emit(PollState(uid: uid, busy: true));
    try {
      final poll = await repo.fetch(url, uid);
      if (!_current(generation, uid)) return;
      _loadedRepository = repo;
      emit(PollState(poll: poll, uid: uid));
    } on Exception {
      if (_current(generation, uid)) emit(PollState(uid: uid, failed: true));
    }
  }

  /// Change a choice while enforcing the server's selection limit.
  void select(String id, {required bool selected}) {
    final poll = state.poll;
    if (state.busy || state.uid != currentUid() || poll?.availability != PollAvailability.available) return;
    if (!poll!.options.any((option) => option.id == id)) return;
    final choices = {...state.choices};
    if (!selected) {
      choices.remove(id);
    } else if (poll.maxChoices == 1) {
      choices
        ..clear()
        ..add(id);
    } else if (choices.length < (poll.maxChoices ?? 0)) {
      choices.add(id);
    }
    emit(PollState(poll: poll, uid: state.uid, choices: Set.unmodifiable(choices)));
  }

  /// One explicit POST, followed by a mandatory authoritative GET.
  Future<void> submit() async {
    final snapshot = state;
    final repo = _loadedRepository;
    final poll = snapshot.poll;
    if (snapshot.busy ||
        snapshot.uid == null ||
        snapshot.uid != currentUid() ||
        repo == null ||
        poll == null ||
        !poll.accepts(snapshot.choices)) {
      return;
    }
    final generation = ++_generation;
    emit(PollState(poll: poll, uid: snapshot.uid, busy: true, choices: snapshot.choices));
    _votesSent.add((snapshot.uid!, url));
    try {
      await repo.vote(poll, snapshot.choices);
    } on Exception {
      // A failed response can still mean the server accepted the vote. Only GET next.
    }
    if (!_current(generation, snapshot.uid)) return;
    try {
      final refreshed = await repo.fetch(url, snapshot.uid);
      if (!_current(generation, snapshot.uid)) return;
      emit(
        PollState(
          poll: refreshed,
          uid: snapshot.uid,
          submissionUnconfirmed: refreshed.availability != PollAvailability.voted,
        ),
      );
    } on Exception {
      if (_current(generation, snapshot.uid)) {
        _loadedRepository = null;
        emit(PollState(uid: snapshot.uid, failed: true, submissionUnconfirmed: true));
      }
    }
  }
}
