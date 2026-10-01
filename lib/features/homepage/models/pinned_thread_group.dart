part of 'models.dart';

/// A list of recommended thread with grouped name in the website homepage.
@MappableClass()
final class PinnedThreadGroup with PinnedThreadGroupMappable {
  /// Constructor.
  const PinnedThreadGroup({required this.title, required this.threadList, this.isRank = false});

  /// Title of this thread group.
  final String title;

  /// List of threads in this group.
  final List<PinnedThread> threadList;

  /// The posting rank tab ("发帖排行"): each row is a user and a post count, not a thread and its author.
  final bool isRank;
}
