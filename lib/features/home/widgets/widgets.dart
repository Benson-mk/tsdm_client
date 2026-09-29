import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

part 'animated_branch_page_view.dart';
part 'home_navigation_bar.dart';
part 'home_navigation_drawer.dart';
part 'home_navigation_rail.dart';
part 'home_tab_tap.dart';

/// Indicator of the selected destination in the bottom bar, the rail and the drawer: the inner radius of the app
/// surfaces instead of the default pill.
const _navigationIndicatorShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(appInnerRadius)),
);

/// Hairline between the navigation and the content, the border color of the app surfaces.
Color _navigationHairline(ColorScheme colorScheme) => colorScheme.outlineVariant.withValues(alpha: 0.6);

/// Divider between the side navigation (rail or drawer) and the content.
class HomeNavigationDivider extends StatelessWidget {
  /// Constructor.
  const HomeNavigationDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      VerticalDivider(width: 1, thickness: 1, color: _navigationHairline(Theme.of(context).colorScheme));
}

/// Group of a destination in the side navigation.
enum _NavigationGroup {
  /// Main entries at the top: home, forums, activities, notifications, profile.
  main,

  /// "More" entries under their section header: title shop, medal center, bank, settings.
  more,
}

/// Bar item in app navigator.
///
/// Items with a [tab] switch the home shell branch (their state is kept, a double tap scrolls them to top); the others
/// open their page above the shell with `pushNamed`, the back button returns to the tab that was selected.
final class _NavigationItem {
  /// Constructor.
  const _NavigationItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.targetPath,
    this.tab,
    this.group = _NavigationGroup.main,
    this.unreadNoticeBadge = false,
    this.needLogin = false,
  });

  /// Item icon.
  ///
  /// Use outline style icons.
  final Icon icon;

  /// Item icon when selected.
  ///
  /// Use normal style icons.
  final Icon selectedIcon;

  /// Name of the item.
  final String label;

  /// Screen path of the item.
  final String targetPath;

  /// Tab of the home shell, null for a page opened above the shell.
  final HomeTab? tab;

  /// Section of the side navigation.
  final _NavigationGroup group;

  /// Show the unread notification count (`NoticeIcon` rules) on the icon.
  final bool unreadNoticeBadge;

  /// The page cannot be used without an account: open the login page instead when there is none.
  final bool needLogin;
}

/// The three home shell tabs, the destinations of the phone navigation bar.
List<_NavigationItem> _buildTabItems(BuildContext context) =>
    _buildNavigationItems(context).where((e) => e.tab != null).toList();

/// All side navigation items (rail and drawer), in display order.
///
/// Every tab of [HomeTab] appears exactly once.
List<_NavigationItem> _buildNavigationItems(BuildContext context) {
  final tr = context.t.navigation;
  return [
    _NavigationItem(
      icon: const Icon(Icons.home_outlined),
      selectedIcon: const Icon(Icons.home),
      label: tr.homepage,
      targetPath: ScreenPaths.homepage,
      tab: HomeTab.home,
    ),
    _NavigationItem(
      icon: const Icon(Icons.topic_outlined),
      selectedIcon: const Icon(Icons.topic),
      label: tr.topics,
      targetPath: ScreenPaths.topic,
      tab: HomeTab.topic,
    ),
    _NavigationItem(
      icon: const Icon(Icons.event_outlined),
      selectedIcon: const Icon(Icons.event),
      label: tr.activities,
      targetPath: ScreenPaths.activities,
    ),
    _NavigationItem(
      icon: const Icon(Icons.notifications_outlined),
      selectedIcon: const Icon(Icons.notifications),
      label: tr.notice,
      targetPath: ScreenPaths.notice,
      unreadNoticeBadge: true,
      // Same rule as the notice button of the app bar, which is disabled without an account.
      needLogin: true,
    ),
    _NavigationItem(
      icon: const Icon(Icons.person_outline),
      selectedIcon: const Icon(Icons.person),
      label: tr.profile,
      // The profile page shows its own "need login" state.
      targetPath: ScreenPaths.loggedUserProfile,
    ),
    _NavigationItem(
      icon: const Icon(Icons.sell_outlined),
      selectedIcon: const Icon(Icons.sell),
      label: tr.titleShop,
      targetPath: ScreenPaths.titleShop,
      group: _NavigationGroup.more,
    ),
    _NavigationItem(
      icon: const Icon(Icons.military_tech_outlined),
      selectedIcon: const Icon(Icons.military_tech),
      label: tr.medalCenter,
      targetPath: ScreenPaths.medalCenter,
      group: _NavigationGroup.more,
    ),
    _NavigationItem(
      icon: const Icon(Icons.account_balance_outlined),
      selectedIcon: const Icon(Icons.account_balance),
      label: tr.bank,
      targetPath: ScreenPaths.bank,
      group: _NavigationGroup.more,
    ),
    _NavigationItem(
      icon: const Icon(Icons.settings_outlined),
      selectedIcon: const Icon(Icons.settings),
      label: tr.settings,
      targetPath: ScreenPaths.settings.path,
      tab: HomeTab.settings,
      group: _NavigationGroup.more,
    ),
  ];
}

/// Index in [items] of the destination showing [tab]: the selected one. The pages opened above the shell cover the
/// navigation, so only tabs are ever selected.
int _selectedIndexOf(List<_NavigationItem> items, HomeTab tab) => items.indexWhere((e) => e.tab == tab);

/// Icon of [item], with the unread notification count when it carries one.
Widget _destinationIcon(_NavigationItem item, {bool selected = false}) {
  final icon = selected ? item.selectedIcon : item.icon;
  return item.unreadNoticeBadge ? _UnreadNoticeIcon(icon) : icon;
}

/// [icon] with the unread notification count, by the rules of `NoticeIcon`: only with an account, only when the unread
/// hint setting is on and only when something is unread. The count is the one of [NotificationStateCubit], which the
/// notification sync keeps (blocked and muted senders already left out); nothing is shown without that cubit.
class _UnreadNoticeIcon extends StatelessWidget {
  const _UnreadNoticeIcon(this.icon);

  final Icon icon;

  @override
  Widget build(BuildContext context) {
    final cubit = context.readOrNull<NotificationStateCubit>();
    if (cubit == null) {
      return icon;
    }
    return BlocBuilder<NotificationStateCubit, NotificationStateInfo>(
      bloc: cubit,
      builder: (context, state) {
        final loggedIn = context.readOrNull<AuthenticationRepository>()?.currentUser != null;
        final showUnreadHint =
            getIt.isRegistered<SettingsRepository>() &&
            getIt.get<SettingsRepository>().currentSettings.showUnreadInfoHint;
        if (!loggedIn || !showUnreadHint || state.total <= 0) {
          return icon;
        }
        final colorScheme = Theme.of(context).colorScheme;
        return Badge(
          label: Text('${state.total}'),
          backgroundColor: colorScheme.error,
          textColor: colorScheme.onError,
          child: icon,
        );
      },
    );
  }
}

/// Section header "More" of the side navigation.
class _NavigationSectionHeader extends StatelessWidget {
  const _NavigationSectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 16, 16, 8),
    child: Semantics(
      header: true,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}
