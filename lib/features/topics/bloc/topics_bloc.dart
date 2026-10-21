import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'topics_bloc.mapper.dart';

part 'topics_event.dart';

part 'topics_state.dart';

/// Bloc of topic.
///
/// The group list comes from the `forum.php` page shared with the homepage: the web page parsed as before
/// ([buildGroupListFromDocument]), or the structured answer of the forum's app API (plugin 2.3.0, `schema: 5`) built
/// from its categories ([forumGroupsFromApi]). Besides its own load and refresh events the bloc re-parses every page
/// published by [ForumHomeRepository] (the homepage refreshes it after a login or an account switch), reloads from
/// the server after a logout, and reloads after a forum was added to or removed from favorites so the "我收藏的版块"
/// panel follows (issues #1, #2).
///
/// The shared page is trusted only when it was served to the current user (the user node in the header of the web
/// page, the `uid` of the structured answer): the cache and the stream replay may still hold the previous account's
/// page after a switch or a logout, and that page must neither be shown nor seed the favorite forums of the new
/// user.
class TopicsBloc extends Bloc<TopicsEvent, TopicsState> with LoggerMixin {
  /// Constructor.
  ///
  /// [authRefreshGrace] is how long the bloc waits for the homepage to publish a fresh page after the logged user
  /// changed before fetching one itself.
  TopicsBloc({
    required ForumHomeRepository forumHomeRepository,
    required AuthenticationRepository authenticationRepository,
    required FavoriteRepository favoriteRepository,
    Duration authRefreshGrace = const Duration(seconds: 5),
  }) : _forumHomeRepository = forumHomeRepository,
       _authenticationRepository = authenticationRepository,
       _favoriteRepository = favoriteRepository,
       _authRefreshGrace = authRefreshGrace,
       super(const TopicsState()) {
    on<TopicsLoadRequested>(_onTopicsLoadRequested);
    on<TopicsRefreshRequested>(_onTopicsRefreshRequested);
    on<TopicsTabSelected>(_onTopicsTabSelected);
    on<TopicsPageUpdated>(_onTopicsPageUpdated);
    on<TopicsAuthChanged>(_onTopicsAuthChanged);

    _pageSub = _forumHomeRepository.pageStream.listen((page) => add(TopicsPageUpdated(page)));
    _authSub = _authenticationRepository.status.pairwise().listen(
      (statuses) => add(TopicsAuthChanged(prev: statuses.first, curr: statuses.last)),
    );
    _favoriteSub = _favoriteRepository.forumFavoritesChanged.listen(
      (_) => add(const TopicsRefreshRequested(silent: true)),
    );
  }

  final ForumHomeRepository _forumHomeRepository;
  final AuthenticationRepository _authenticationRepository;
  final FavoriteRepository _favoriteRepository;
  final Duration _authRefreshGrace;

  late final StreamSubscription<ForumHomePage> _pageSub;
  late final StreamSubscription<List<AuthStatus>> _authSub;
  late final StreamSubscription<void> _favoriteSub;

  /// Pending fallback fetch after the logged user changed, cancelled when a page arrives in time.
  Timer? _authRefreshTimer;

  /// The page the current group list was parsed from.
  ///
  /// A fetch of this bloc returns the page and publishes the same instance on the stream: parse it once.
  ForumHomePage? _shownPage;

  /// The page ignored for belonging to another user, for which one forced fetch was issued.
  ///
  /// The cache and the stream replay hand out the same instance, so it is recognised when it comes again. Another
  /// page that still does not match is shown (never seeded) instead of fetching forever; the next auth transition
  /// allows one more.
  ForumHomePage? _stalePage;

  Future<void> _onTopicsLoadRequested(TopicsLoadRequested event, Emitter<TopicsState> emit) async {
    emit(state.copyWith(status: TopicsStatus.loading));
    final pageEither = await _forumHomeRepository.fetchTopicPage().run();
    if (pageEither.isLeft()) {
      handle(pageEither.unwrapErr());
      emit(state.copyWith(status: TopicsStatus.failed));
      return;
    }
    _emitParsed(pageEither.unwrap(), emit);
  }

  Future<void> _onTopicsRefreshRequested(TopicsRefreshRequested event, Emitter<TopicsState> emit) async {
    if (!event.silent) {
      emit(state.copyWith(status: TopicsStatus.loading));
    }

    final pageEither = await _forumHomeRepository.fetchTopicPage(force: true).run();
    if (pageEither.isLeft()) {
      handle(pageEither.unwrapErr());
      if (!event.silent || !state.status.isSuccess) {
        emit(state.copyWith(status: TopicsStatus.failed));
      }
      return;
    }
    _emitParsed(pageEither.unwrap(), emit);
  }

  void _onTopicsTabSelected(TopicsTabSelected event, Emitter<TopicsState> emit) {
    emit(state.copyWith(topicsTab: event.tabIndex));
  }

  void _onTopicsPageUpdated(TopicsPageUpdated event, Emitter<TopicsState> emit) {
    if (identical(event.page, _shownPage)) {
      return;
    }
    if (_emitParsed(event.page, emit)) {
      _authRefreshTimer?.cancel();
      _authRefreshTimer = null;
    }
  }

  void _onTopicsAuthChanged(TopicsAuthChanged event, Emitter<TopicsState> emit) {
    final curr = event.curr;
    if (event.prev != curr) {
      // The cached page belongs to the previous user (or guest): a bloc created from now on must go to the server
      // instead of showing it.
      _forumHomeRepository.invalidate();
      _stalePage = null;
    }
    if (curr is AuthStatusNotAuthed) {
      // Logged out: the cached page still belongs to the previous user, show the guest index.
      _authRefreshTimer?.cancel();
      _authRefreshTimer = null;
      add(const TopicsRefreshRequested(silent: true));
      return;
    }
    if (curr is AuthStatusAuthed && event.prev != curr) {
      // Logged in or switched account: the homepage refreshes the shared page and it arrives through
      // [TopicsPageUpdated]; fetch one here only when that does not happen in time.
      _authRefreshTimer?.cancel();
      _authRefreshTimer = Timer(_authRefreshGrace, () {
        _authRefreshTimer = null;
        if (!isClosed) {
          add(const TopicsRefreshRequested(silent: true));
        }
      });
    }
  }

  /// Show [page] when it belongs to the current user, otherwise ignore it and fetch a fresh one once.
  ///
  /// Returns whether the page was shown.
  bool _emitParsed(ForumHomePage page, Emitter<TopicsState> emit) {
    final currentUid = _authenticationRepository.currentUser?.uid;
    final pageUid = page.servedUid;
    if (pageUid != currentUid) {
      if (identical(page, _stalePage)) {
        return false;
      }
      if (_stalePage == null) {
        info('forum index of user $pageUid ignored, current user is $currentUid: fetching again');
        _stalePage = page;
        add(const TopicsRefreshRequested(silent: true));
        return false;
      }
      warning('forum index of user $pageUid shown to user $currentUid, favorite forums not seeded');
    }
    _shownPage = page;
    emit(_parse(page, seedUid: pageUid));
    return true;
  }

  /// Parse the group list and seed the favorite forums cache of [seedUid] from the "我收藏的版块" panel, if any.
  ///
  /// The web page: the panel's forums are the favorites. The structured answer: `favorite_forums` names every
  /// favorite, among them one the panel may not list (its `favorites` since plugin 2.8.1, before that read from the
  /// page or looked up among the categories, [forumGroupsFromApi]).
  TopicsState _parse(ForumHomePage page, {required int? seedUid}) {
    final List<ForumGroup> forumGroupList;
    final Iterable<int> favorites;
    final bool panelInPage;
    switch (page) {
      case ForumHomeWebPage(:final document):
        forumGroupList = buildGroupListFromDocument(document);
        favorites = forumGroupList.where((e) => e.isFavorites).expand((e) => e.forumList).map((e) => e.forumID);
        // Enough to tell "the server did not render the panel" from "the parser missed it" from a log alone (#1).
        panelInPage = document.querySelector('div#ct')?.innerHtml?.contains('do=favorite&amp;type=forum') ?? false;
      case ForumHomeApiPage(:final json):
        forumGroupList = forumGroupsFromApi(json);
        favorites = favoriteForumIdsOf(json);
        panelInPage = favorites.isNotEmpty;
    }
    debug(
      'forum index parsed: ${forumGroupList.length} groups ${forumGroupList.map((e) => e.name).toList()}, '
      'favorite forums $favorites, favorites panel in page: $panelInPage',
    );
    if (seedUid != null && seedUid == _authenticationRepository.currentUser?.uid) {
      _favoriteRepository.seedForumFavorites(uid: seedUid, fids: favorites.map((e) => '$e'));
    }
    return state.copyWith(status: TopicsStatus.success, forumGroupList: forumGroupList);
  }

  @override
  Future<void> close() async {
    _authRefreshTimer?.cancel();
    await _pageSub.cancel();
    await _authSub.cancel();
    await _favoriteSub.cancel();
    await super.close();
  }
}
