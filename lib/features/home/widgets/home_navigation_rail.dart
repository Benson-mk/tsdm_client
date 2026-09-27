part of 'widgets.dart';

/// [NavigationRail] used in home page.
///
/// Use in medium window size.
class HomeNavigationRail extends StatefulWidget {
  /// Constructor.
  const HomeNavigationRail({super.key});

  @override
  State<HomeNavigationRail> createState() => _HomeNavigationRailState();
}

class _HomeNavigationRailState extends State<HomeNavigationRail> {
  final _doubleTap = HomeTabDoubleTapDetector();

  @override
  Widget build(BuildContext context) {
    final barItems = _buildNavigationItems(context);
    final colorScheme = Theme.of(context).colorScheme;

    // Same look as the bottom bar and the drawer: low container color, rounded indicator, labels always shown.
    return NavigationRail(
      groupAlignment: 0,
      backgroundColor: colorScheme.surfaceContainerLow,
      indicatorShape: _navigationIndicatorShape,
      labelType: NavigationRailLabelType.all,
      destinations: barItems
          .map((e) => NavigationRailDestination(icon: e.icon, selectedIcon: e.selectedIcon, label: Text(e.label)))
          .toList(),
      selectedIndex: context.watch<HomeCubit>().state.tab.index,
      onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
    );
  }
}
