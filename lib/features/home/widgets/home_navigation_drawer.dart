part of 'widgets.dart';

/// [NavigationDrawer] used in home page.
///
/// Use in large or extra-large window.
class HomeNavigationDrawer extends StatefulWidget {
  /// Constructor.
  const HomeNavigationDrawer({super.key});

  @override
  State<HomeNavigationDrawer> createState() => _HomeNavigationDrawerState();
}

class _HomeNavigationDrawerState extends State<HomeNavigationDrawer> {
  final _doubleTap = HomeTabDoubleTapDetector();

  @override
  Widget build(BuildContext context) {
    final barItems = _buildNavigationItems(context);
    final colorScheme = Theme.of(context).colorScheme;
    // Same look as the bottom bar and the rail: low container color (shared with the brand block above it), rounded
    // indicator.
    return NavigationDrawer(
      backgroundColor: colorScheme.surfaceContainerLow,
      elevation: 0,
      indicatorShape: _navigationIndicatorShape,
      selectedIndex: context.watch<HomeCubit>().state.tab.index,
      onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
      children: barItems
          .map((e) => NavigationDrawerDestination(icon: e.icon, selectedIcon: e.selectedIcon, label: Text(e.label)))
          .toList(),
    );
  }
}
