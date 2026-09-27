part of 'widgets.dart';

/// [NavigationBar] used in home page.
///
/// Use in compact window.
class HomeNavigationBar extends StatefulWidget {
  /// Constructor.
  const HomeNavigationBar({super.key});

  @override
  State<HomeNavigationBar> createState() => _HomeNavigationBarState();
}

class _HomeNavigationBarState extends State<HomeNavigationBar> {
  final _doubleTap = HomeTabDoubleTapDetector();

  @override
  Widget build(BuildContext context) {
    final barItems = _buildNavigationItems(context);
    final colorScheme = Theme.of(context).colorScheme;

    // Same look as the side navigation: low container color, rounded indicator, hairline towards the content.
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _navigationHairline(colorScheme))),
      ),
      child: NavigationBar(
        backgroundColor: colorScheme.surfaceContainerLow,
        elevation: 0,
        indicatorShape: _navigationIndicatorShape,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: barItems
            .map((e) => NavigationDestination(icon: e.icon, selectedIcon: e.selectedIcon, label: e.label))
            .toList(),
        selectedIndex: context.watch<HomeCubit>().state.tab.index,
        onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
      ),
    );
  }
}
