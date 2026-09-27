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
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    // Generous estimate of the height the destinations need (labels are one line); too much only adds room to scroll.
    final contentHeight =
        _railVerticalPadding +
        _railGroupGap +
        barItems.length * (_railDestinationHeight + _railLabelHeight * textScale);

    // Same look as the bottom bar and the drawer: low container color, rounded indicator, labels always shown.
    final rail = NavigationRail(
      groupAlignment: -1,
      backgroundColor: colorScheme.surfaceContainerLow,
      indicatorShape: _navigationIndicatorShape,
      labelType: NavigationRailLabelType.all,
      destinations: [
        for (final (i, e) in barItems.indexed)
          NavigationRailDestination(
            icon: _destinationIcon(e),
            selectedIcon: _destinationIcon(e, selected: true),
            label: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            // A gap marks the "more" group: the rail has no room for the section header of the drawer.
            padding: i > 0 && e.group != barItems[i - 1].group ? const EdgeInsets.only(top: _railGroupGap) : null,
          ),
      ],
      selectedIndex: _selectedIndexOf(barItems, context.watch<HomeCubit>().state.tab),
      onDestinationSelected: (index) => _onHomeDestinationSelected(context, _doubleTap, barItems, index),
    );

    // NavigationRail does not scroll: nine destinations overflow a short window (landscape phone, small tablet, large
    // text). It gets the window height, or more when its destinations need it, inside a scroll view.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        primary: false,
        child: SizedBox(
          height: constraints.hasBoundedHeight ? math.max(constraints.maxHeight, contentHeight) : contentHeight,
          child: rail,
        ),
      ),
    );
  }
}

/// Space above and below the destinations of the rail.
const _railVerticalPadding = 24.0;

/// Gap before the first destination of the "more" group in the rail.
const _railGroupGap = 16.0;

/// Height of a rail destination without its label: indicator, spacings and touch padding.
const _railDestinationHeight = 64.0;

/// Height of the one line label of a rail destination at text scale 1.
const _railLabelHeight = 24.0;
