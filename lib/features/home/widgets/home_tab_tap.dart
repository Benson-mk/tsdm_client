part of 'widgets.dart';

/// Tells a double tap on a home navigation destination from ordinary taps.
///
/// Shared by the navigation bar (compact window), the navigation rail (medium window) and the navigation drawer
/// (large window) so all behave the same (#103): the second tap on the same destination within [interval] is a double tap, a third tap starts over.
final class HomeTabDoubleTapDetector {
  /// Time between the two taps of a double tap.
  static const interval = Duration(milliseconds: 500);

  /// Source of the current time.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  DateTime? _lastTapTime;
  int? _lastTapIndex;

  /// Record a tap on destination [index] and return true if it completes a double tap.
  bool tap(int index) {
    final now = clock();
    final last = _lastTapTime;
    if (_lastTapIndex == index && last != null && now.difference(last) < interval) {
      // Forget the pair so a triple tap is not a second double tap.
      _lastTapTime = null;
      _lastTapIndex = null;
      return true;
    }
    _lastTapTime = now;
    _lastTapIndex = index;
    return false;
  }
}

/// Handle a tap on destination [index] of [items].
///
/// Tabs: a double tap asks the page of that tab to scroll to top (or refresh when already there) through
/// [scrollToTopStream] with the index of the [HomeTab], instead of routing a second time; any other tap switches to the
/// tab.
///
/// Other destinations push their page above the shell (the back button returns to the selected tab); the second tap of
/// a double tap is dropped so a quick double tap opens one page, not two. A page needing an account opens the login page
/// when there is none.
void _onHomeDestinationSelected(
  BuildContext context,
  HomeTabDoubleTapDetector detector,
  List<_NavigationItem> items,
  int index,
) {
  final item = items[index];
  final doubleTap = detector.tap(index);
  final tab = item.tab;
  if (tab == null) {
    if (doubleTap) {
      return;
    }
    final loggedIn = context.readOrNull<AuthenticationRepository>()?.currentUser != null;
    unawaited(context.pushNamed(item.needLogin && !loggedIn ? ScreenPaths.login : item.targetPath));
    return;
  }
  if (doubleTap) {
    scrollToTopStream.add(ScrollToTopEvent(tab.index));
    return;
  }
  context.read<HomeCubit>().setTab(tab);
  context.goNamed(item.targetPath);
}
