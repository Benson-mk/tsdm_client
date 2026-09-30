import 'dart:convert';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Who the mention picker can offer.
final class MentionCandidates {
  /// Constructor.
  const MentionCandidates({
    required this.friends,
    required this.others,
    this.friendsMessage,
    this.recent = const [],
    this.siteSearch = false,
  });

  /// Nothing at all.
  static const empty = MentionCandidates(friends: [], others: []);

  /// Users the current user mentioned recently, from the `atplus` plugin; empty without it.
  final List<Friend> recent;

  /// Whether the forum's `atplus` plugin answered: then any user of the site can be searched by name or uid
  /// ([MentionRepository.searchUsers]).
  final bool siteSearch;

  /// The current user's own friends, in the order of the friends list, unique by uid.
  final List<Friend> friends;

  /// Names on the official `@` list (`misc.php?mod=getatuser`) that are not in [friends], compared case insensitive.
  ///
  /// Empty when the `atplus` plugin answered ([siteSearch]): its search replaces that list.
  final List<String> others;

  /// Why the friends list could not be read: the privacy or login notice of the page, or the error of the request.
  ///
  /// Null when the list was read (possibly empty) or was not asked for because nobody is logged in.
  final String? friendsMessage;
}

/// Where the mention picker gets its candidates.
///
/// The forum's `atplus` plugin (`plugin.php?id=atplus:search`, the web @ panel since 2026-09) comes first: `op=init`
/// gives the users mentioned recently and the friends, `op=search` finds any user of the site by name or uid. When the
/// plugin does not answer (not installed, or an error), the stock sources are used instead.
///
/// Two stock sources are merged, and one failing does not fail the whole load:
///
/// * the current user's own friends list (`home.php?mod=space&uid=SELF&do=friend`, 24 per page, up to
///   [maxFriendPages] pages), which carries uid, avatar and user group;
/// * the official `@` list, names only, which may be empty for the user group even when the user has friends.
///
/// The result is cached per instance and per uid, so reopening the picker does not ask the server again unless
/// `force` is given; a load that failed on one side is not cached so the next open retries it. The official `@` list
/// is per account (and empty for a guest), so it is asked again whenever the uid differs from the one it was loaded
/// for, even though [EditorRepository] keeps its own copy.
final class MentionRepository with LoggerMixin {
  /// Constructor.
  MentionRepository({FriendRepository friendRepository = const FriendRepository(), EditorRepository? editorRepository})
    : _friendRepository = friendRepository,
      _editorRepository = editorRepository ?? EditorRepository();

  /// How many pages of the own friends list are followed at most (24 friends per page).
  static const maxFriendPages = 5;

  final FriendRepository _friendRepository;
  final EditorRepository _editorRepository;

  MentionCandidates? _cache;
  String? _cachedUid;

  /// Whether the `@` list held by [_editorRepository] was loaded, and for which uid.
  bool _atLoaded = false;
  String? _atUid;

  /// The candidates cached by the last complete load, if any.
  MentionCandidates? get cached => _cache;

  /// Load the own friends list of [selfUid], following the next page links up to [maxFriendPages] pages.
  ///
  /// Friends are unique by uid. A privacy or login notice on the first page becomes [MentionCandidates.friendsMessage]
  /// with no friends; a later page failing keeps what was read before it.
  AsyncEither<({List<Friend> friends, String? message})> loadOwnFriends({required String selfUid}) =>
      AsyncEither(() async {
        final friends = <Friend>[];
        final seen = <String>{};
        String? url = FriendRepository.listUrl(uid: selfUid);
        for (var page = 0; page < maxFriendPages && url != null; page++) {
          switch (await _friendRepository.fetchPage(url).run()) {
            case Left(:final value):
              if (page == 0) {
                return Left(value);
              }
              handle(value);
              warning('mention: friends page ${page + 1} failed, keep ${friends.length} friends');
              return Right((friends: friends, message: null));
            case Right(:final value):
              if (page == 0 && (value.message != null || value.needLogin)) {
                return Right((friends: const <Friend>[], message: value.message ?? 'need login'));
              }
              for (final friend in value.items) {
                if (seen.add(friend.uid)) {
                  friends.add(friend);
                }
              }
              url = value.nextPageUrl;
          }
        }
        return Right((friends: friends, message: null));
      });

  /// Url of the `atplus` plugin's user api.
  static const atplusUrl = '$baseUrl/plugin.php?id=atplus:search';

  /// Ask the `atplus` plugin with the form [data]; the decoded JSON, or null when the plugin did not answer with it.
  Future<Object?> _atplus(Map<String, String> data) async {
    switch (await getIt.get<NetClientProvider>().postForm(atplusUrl, data: data).run()) {
      case Left(:final value):
        debug('mention: atplus did not answer: $value');
        return null;
      case Right(:final value):
        final body = value.data;
        if (body is Map) {
          return body;
        }
        try {
          return jsonDecode('$body');
        } on FormatException {
          return null;
        }
    }
  }

  /// Users of the whole site whose name or uid matches [keyword], through the `atplus` plugin.
  ///
  /// Fails when the plugin does not answer; only meaningful when [MentionCandidates.siteSearch] is set.
  AsyncEither<List<Friend>> searchUsers(String keyword) => AsyncEither(() async {
    final users = parseAtplusUsers(await _atplus({'op': 'search', 'q': keyword}), 'list', base: baseUrl);
    return users == null ? Left(ServerRespondedErrorException('atplus search unavailable')) : Right(users);
  });

  /// Load the candidates: own friends of [selfUid] (skipped when null, nobody logged in) and the official `@` list.
  ///
  /// The `atplus` plugin is asked first for a logged in user; its recent and friends lists replace the stock sources
  /// when it answers. Fails only when nothing could be loaded at all.
  AsyncEither<MentionCandidates> loadCandidates({required String? selfUid, bool force = false}) =>
      AsyncEither(() async {
        final cached = _cache;
        if (cached != null && !force && _cachedUid == selfUid) {
          return Right(cached);
        }

        if (selfUid != null) {
          final init = await _atplus(const {'op': 'init'});
          final recent = parseAtplusUsers(init, 'recent', base: baseUrl);
          final friends = parseAtplusUsers(init, 'friends', base: baseUrl);
          if (recent != null && friends != null) {
            final candidates = MentionCandidates(recent: recent, friends: friends, others: const [], siteSearch: true);
            _cache = candidates;
            _cachedUid = selfUid;
            return Right(candidates);
          }
        }

        // Both requests run at the same time.
        final friendsFuture = selfUid == null ? null : loadOwnFriends(selfUid: selfUid).run();
        // The `@` list cached inside the editor repository is only reused for the uid it was loaded for.
        final atFuture = force || !_atLoaded || _atUid != selfUid
            ? _editorRepository.loadAtUsers().run()
            : _editorRepository.searchUserByName(keyword: '').run();
        final friendsResult = friendsFuture == null ? null : await friendsFuture;
        final atResult = await atFuture;

        var friends = const <Friend>[];
        String? friendsMessage;
        var friendsFailed = false;
        if (friendsResult != null) {
          switch (friendsResult) {
            case Left(:final value):
              handle(value);
              friendsFailed = true;
              friendsMessage = '$value';
            case Right(:final value):
              friends = value.friends;
              friendsMessage = value.message;
          }
        }

        var others = const <String>[];
        AppException? atError;
        switch (atResult) {
          case Left(:final value):
            handle(value);
            atError = value;
          case Right(:final value):
            _atLoaded = true;
            _atUid = selfUid;
            final known = friends.map((e) => e.username.toLowerCase()).toSet();
            others = value.where((e) => known.add(e.toLowerCase())).toList();
        }

        if (atError != null && (friendsFailed || selfUid == null)) {
          return Left(atError);
        }
        final candidates = MentionCandidates(friends: friends, others: others, friendsMessage: friendsMessage);
        if (atError == null && !friendsFailed) {
          _cache = candidates;
          _cachedUid = selfUid;
        }
        return Right(candidates);
      });
}
