part of 'widgets.dart';

/// Duration of the branch switch slide.
const _branchSlideDuration = Duration(milliseconds: 300);

/// Hosts the shell branches in a [PageView], so switching a bottom navigation tab slides horizontally instead of
/// jumping. Every branch keeps its own navigator and state because the pages stay mounted.
class AnimatedBranchPageView extends StatefulWidget {
  /// Constructor.
  const AnimatedBranchPageView({required this.navigationShell, required this.children, super.key});

  /// The shell that owns the branches and reports the current one.
  final StatefulNavigationShell navigationShell;

  /// The branch navigators, in branch order.
  final List<Widget> children;

  @override
  State<AnimatedBranchPageView> createState() => _AnimatedBranchPageViewState();
}

class _AnimatedBranchPageViewState extends State<AnimatedBranchPageView> {
  late final PageController _controller = PageController(initialPage: widget.navigationShell.currentIndex);

  @override
  void didUpdateWidget(AnimatedBranchPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = widget.navigationShell.currentIndex;
    if (index != oldWidget.navigationShell.currentIndex) {
      unawaited(_controller.animateToPage(index, duration: _branchSlideDuration, curve: Curves.easeInOut));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageView(
    controller: _controller,
    // The navigation bar drives the tab. Not swipeable, so the scrollables inside the branches keep their own gestures.
    physics: const NeverScrollableScrollPhysics(),
    children: widget.children,
  );
}
