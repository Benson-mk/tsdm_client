part of 'user_mention_cubit.dart';

/// Status of loading progress.
enum UserMentionStatus {
  /// Initial state.
  initial,

  /// Loading data.
  loading,

  /// Got data.
  success,

  /// Failed to load.
  failure,
}

/// State of the mention picker: the loaded candidates and the keyword they are filtered by.
@MappableClass()
final class UserMentionState with UserMentionStateMappable {
  /// Constructor.
  const UserMentionState({
    required this.recommendStatus,
    required this.friends,
    required this.others,
    required this.keyword,
    this.friendsMessage,
    this.recent = const [],
    this.siteSearch = false,
    this.searchStatus = UserMentionStatus.initial,
    this.searchKeyword = '',
    this.searchResults = const [],
  });

  /// Empty state.
  factory UserMentionState.empty() =>
      const UserMentionState(recommendStatus: UserMentionStatus.initial, friends: [], others: [], keyword: '');

  /// Status of loading the candidates.
  final UserMentionStatus recommendStatus;

  /// The current user's own friends.
  final List<Friend> friends;

  /// Names on the official `@` list that are not friends.
  final List<String> others;

  /// Keyword the lists are filtered by, trimmed; empty shows everyone.
  final String keyword;

  /// Why the friends list could not be read, see [MentionCandidates.friendsMessage].
  final String? friendsMessage;

  /// Users mentioned recently, see [MentionCandidates.recent].
  final List<Friend> recent;

  /// Whether the whole site can be searched, see [MentionCandidates.siteSearch].
  final bool siteSearch;

  /// Status of the site search for [searchKeyword].
  final UserMentionStatus searchStatus;

  /// Keyword the [searchResults] belong to.
  final String searchKeyword;

  /// Users of the site found for [searchKeyword].
  final List<Friend> searchResults;

  bool _matches(String name) => keyword.isEmpty || name.toLowerCase().contains(keyword.toLowerCase());

  /// Friends matching the keyword.
  List<Friend> get visibleFriends => friends.where((e) => _matches(e.username)).toList();

  /// Recently mentioned users matching the keyword.
  List<Friend> get visibleRecent => recent.where((e) => _matches(e.username)).toList();

  /// Site search results of the current keyword that are not already shown as recent or friends.
  List<Friend> get visibleSearchResults {
    if (searchKeyword != keyword) {
      return const [];
    }
    final shown = {...visibleRecent.map((e) => e.uid), ...visibleFriends.map((e) => e.uid)};
    return searchResults.where((e) => !shown.contains(e.uid)).toList();
  }

  /// Other names matching the keyword.
  List<String> get visibleOthers => others.where(_matches).toList();

  /// Whether a candidate has exactly the keyword as name (case insensitive).
  bool get hasExactMatch {
    final k = keyword.toLowerCase();
    bool same(Friend e) => e.username.toLowerCase() == k;
    return k.isNotEmpty &&
        (friends.any(same) ||
            recent.any(same) ||
            (searchKeyword == keyword && searchResults.any(same)) ||
            others.any((e) => e.toLowerCase() == k));
  }
}
