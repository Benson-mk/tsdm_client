import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/widgets/daily_red_packet_button.dart';
import 'package:tsdm_client/features/settings/widgets/support_development_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Corner radius of the homepage cards.
const homeCardRadius = 18.0;

/// Shape shared by the homepage cards: rounded, with a hairline border in the theme's outline variant.
ShapeBorder homeCardShape(BuildContext context) => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(homeCardRadius),
  side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6)),
);

/// Greeting text for the local [hour].
String homeGreeting(BuildContext context, int hour, String name) {
  final tr = context.t.homepage.greeting;
  return switch (hour) {
    >= 5 && < 11 => tr.morning(name: name),
    >= 11 && < 18 => tr.afternoon(name: name),
    >= 18 && < 23 => tr.evening(name: name),
    _ => tr.night(name: name),
  };
}

/// First card of the homepage: greeting, the current account's secondary title and today's things to do.
///
/// Check-in, the daily red packet and activities used to crowd the app bar; they are the actions of the day here.
/// Only data the forum provides is shown: the today count of the forum status bar, no streaks or invented numbers.
class HomeGreetingCard extends StatelessWidget {
  /// Constructor.
  const HomeGreetingCard({
    required this.username,
    required this.uid,
    required this.forumStatus,
    required this.dailyRedPacket,
    required this.formHash,
    required this.compact,
    super.key,
  });

  /// Name of the logged in account.
  final String username;

  /// Uid of the logged in account, for its title badge.
  final int? uid;

  /// Forum statistics from the homepage, [ForumStatus.empty] when the page had none.
  final ForumStatus forumStatus;

  /// Today's red packet, null when there is none or it was claimed.
  final DailyRedPacketConfig? dailyRedPacket;

  /// Form hash required to claim [dailyRedPacket].
  final String? formHash;

  /// Narrow layout: actions stacked under the greeting.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final now = DateTime.now();
    final hasStatus = forumStatus != const ForumStatus.empty();

    final greeting = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${context.t.appName} · ${MaterialLocalizations.of(context).formatMediumDate(now)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.labelMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.w600),
        ),
        sizedBoxW4H4,
        Text(
          homeGreeting(context, now.hour, username),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (compact ? textTheme.titleLarge : textTheme.headlineSmall)?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (hasStatus) ...[
          sizedBoxW4H4,
          Text(
            context.t.homepage.todayPosts(count: forumStatus.todayCount),
            style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );

    final redPacket = dailyRedPacket;
    final hash = formHash;
    final quickActions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (redPacket != null && hash != null)
          DailyRedPacketButton(
            key: ValueKey('dailyRedPacket-${redPacket.dateFlag}'),
            config: redPacket,
            formHash: hash,
            labeled: true,
          ),
        _QuickAction(
          icon: Icons.event_outlined,
          label: context.t.activitiesPage.title,
          onPressed: () async => context.pushNamed(ScreenPaths.activities),
        ),
        _QuickAction(
          icon: Icons.workspace_premium_outlined,
          label: context.t.medalTitleHub.title,
          onPressed: () async => context.pushNamed(ScreenPaths.medalTitleHub),
        ),
      ],
    );

    final checkin = CheckinButton(enableSnackBar: true, label: context.t.homepage.welcome.checkin);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      color: colorScheme.surfaceContainerLow,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topRight,
            radius: 1.4,
            colors: [colorScheme.primaryContainer.withValues(alpha: 0.55), colorScheme.surfaceContainerLow],
            stops: const [0, 0.6],
          ),
        ),
        child: Padding(
          padding: compact ? edgeInsetsL16T16R16B16 : edgeInsetsL24T24R24B24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: greeting),
                  sizedBoxW12H12,
                  CurrentAccountTitleBadge(uid: uid, width: compact ? 84 : 120),
                ],
              ),
              SizedBox(height: compact ? 14 : 20),
              if (compact) ...[
                checkin,
                sizedBoxW12H12,
                quickActions,
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(constraints: const BoxConstraints(minWidth: 180), child: checkin),
                    sizedBoxW12H12,
                    Expanded(child: quickActions),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
    icon: Icon(icon),
    label: Text(label),
    onPressed: onPressed,
  );
}

/// The three counters of the forum status bar: today, yesterday and all posts.
class HomeForumStatsCard extends StatelessWidget {
  /// Constructor.
  const HomeForumStatsCard(this.forumStatus, {super.key});

  /// Forum statistics.
  final ForumStatus forumStatus;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.forumStatus;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    Widget cell(String label, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
    final divider = SizedBox(height: 40, child: VerticalDivider(width: 20, color: colorScheme.outlineVariant));

    return Card(
      margin: EdgeInsets.zero,
      shape: homeCardShape(context),
      child: Padding(
        padding: edgeInsetsL16T12R16B12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t.homepage.forumActivity, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            sizedBoxW8H8,
            Row(
              children: [
                cell(tr.today, forumStatus.todayCount),
                divider,
                cell(tr.yesterday, forumStatus.yesterdayCount),
                divider,
                cell(tr.threads, forumStatus.threadCount),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Entry of the voluntary support dialog: visible, but not in the way of the threads.
class HomeSupportCard extends StatelessWidget {
  /// Constructor.
  const HomeSupportCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      child: InkWell(
        onTap: () async => showDialog<void>(context: context, builder: (_) => const SupportDevelopmentDialog()),
        child: Padding(
          padding: edgeInsetsL16T12R16B12,
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(Icons.favorite_border, color: colorScheme.onTertiaryContainer),
                ),
              ),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t.aboutPage.supportDevelopment,
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    sizedBoxW2H2,
                    Text(
                      context.t.aboutPage.supportDevelopmentSubtitle,
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    sizedBoxW2H2,
                    Text(
                      context.t.homepage.supportNote,
                      style: textTheme.labelSmall?.copyWith(color: colorScheme.tertiary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fixed entries of pages that are not top level destinations, the medal & title hub first.
class HomeToolsCard extends StatelessWidget {
  /// Constructor.
  const HomeToolsCard({required this.columns, super.key});

  /// Number of entries per row.
  final int columns;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage;
    final textTheme = Theme.of(context).textTheme;
    final entries = <(IconData, String, String)>[
      (Icons.workspace_premium_outlined, context.t.medalTitleHub.title, ScreenPaths.medalTitleHub),
      (Icons.article_outlined, tr.welcome.myThread, ScreenPaths.myThread),
      (Icons.star_outline, tr.welcome.favorite, ScreenPaths.favorite),
      (Icons.history_outlined, tr.welcome.history, ScreenPaths.threadVisitHistory),
      (Icons.account_balance_outlined, context.t.bank.title, ScreenPaths.bank),
    ];
    return Card(
      margin: EdgeInsets.zero,
      shape: homeCardShape(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr.tools, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            sizedBoxW12H12,
            LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 8.0;
                final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final (icon, label, path) in entries)
                      SizedBox(
                        width: width,
                        child: _ToolButton(icon: icon, label: label, onTap: () async => context.pushNamed(path)),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: colorScheme.primary),
                sizedBoxW8H8,
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
