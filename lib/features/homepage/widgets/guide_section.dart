import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/homepage/cubit/guide_index_cubit.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Opens the full guide list page ([ScreenPaths.latestThread]) for [url], titled [title].
Future<void> _openGuideList(BuildContext context, String url, String title) async =>
    context.pushNamed(ScreenPaths.latestThread, queryParameters: {'url': url, 'title': title});

/// Homepage section showing the modules of the forum guide index page (GitHub #12).
///
/// `forum.php?mod=guide&view=index` lists 最新热门, 最新精华, 最新回复 and 最新发表 with a handful of threads each.
/// The modules are tabs of one card so the threads start right below the tab row instead of four stacked cards; the
/// 更多 button opens the full list page of the selected module and 抢沙发, which the page only offers in its nav row,
/// opens its list page. The section owns its [GuideIndexCubit]: the homepage rebuilds this widget after every refresh,
/// so the page is fetched again together with the rest of the homepage.
class GuideSection extends StatelessWidget {
  /// Constructor.
  const GuideSection({this.maxCount = 10, this.repository, super.key});

  /// Maximum number of threads shown per module; the page lists more, the rest is one tap away.
  final int maxCount;

  /// Repository override (tests); the real one is used when null.
  final GuideIndexRepository? repository;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final cubit = GuideIndexCubit(repository ?? const GuideIndexRepository());
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocBuilder<GuideIndexCubit, GuideIndexState>(
        builder: (context, state) => _GuideFeedCard(state, maxCount: maxCount),
      ),
    );
  }
}

class _GuideFeedCard extends StatefulWidget {
  const _GuideFeedCard(this.state, {required this.maxCount});

  final GuideIndexState state;
  final int maxCount;

  @override
  State<_GuideFeedCard> createState() => _GuideFeedCardState();
}

class _GuideFeedCardState extends State<_GuideFeedCard> {
  /// View key of the selected module, kept across reloads; the first module when unknown.
  String? _selectedView;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.guide;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final state = widget.state;
    final modules = state.modules;
    final matching = modules.where((e) => e.view == _selectedView);
    final selected = matching.isNotEmpty ? matching.first : (modules.isNotEmpty ? modules.first : null);

    final Widget body;
    if ((state.status == GuideIndexStatus.initial || state.status == GuideIndexStatus.loading) && modules.isEmpty) {
      body = const Padding(padding: edgeInsetsL12T12R12B12, child: CenteredCircularIndicator());
    } else if (state.status == GuideIndexStatus.failure) {
      body = ListTile(
        leading: const Icon(Icons.refresh_outlined),
        title: Text(tr.failed),
        onTap: () async => context.read<GuideIndexCubit>().load(),
      );
    } else if (selected == null) {
      body = Padding(
        padding: edgeInsetsL16T16R16B16,
        child: Text(tr.empty, style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline)),
      );
    } else {
      body = GuideModuleList(selected, maxCount: widget.maxCount);
    }

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.t.homepage.guideTitle,
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected != null)
                  TextButton.icon(
                    onPressed: () async => _openGuideList(context, selected.moreUrl, selected.title),
                    icon: const Icon(Icons.chevron_right_outlined),
                    iconAlignment: IconAlignment.end,
                    label: Text(tr.more),
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: edgeInsetsL8R8,
            child: Row(
              children: [
                for (final module in modules)
                  _GuideTab(
                    label: module.title,
                    selected: module == selected,
                    onTap: () => setState(() => _selectedView = module.view),
                  ),
                sizedBoxW8H8,
                ActionChip(
                  key: const ValueKey('guide-sofa'),
                  avatar: const Icon(Icons.weekend_outlined),
                  label: Text(tr.sofa),
                  onPressed: () async => _openGuideList(context, guideUrl('sofa'), tr.sofa),
                ),
                sizedBoxW8H8,
              ],
            ),
          ),
          Divider(height: 1, color: colorScheme.outlineVariant),
          body,
        ],
      ),
    );
  }
}

/// A module tab with an underline when selected.
class _GuideTab extends StatelessWidget {
  const _GuideTab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
        child: Container(
          constraints: const BoxConstraints(minHeight: 46),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: selected ? colorScheme.primary : Colors.transparent, width: 3),
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.bold : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Threads of one guide module, up to [maxCount], or the page's own empty message.
class GuideModuleList extends StatelessWidget {
  /// Constructor.
  const GuideModuleList(this.module, {this.maxCount = 10, super.key});

  /// The module to show.
  final GuideModule module;

  /// Maximum number of threads shown.
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.guide;
    final colorScheme = Theme.of(context).colorScheme;
    if (module.items.isEmpty) {
      return Padding(
        padding: edgeInsetsL16T16R16B16,
        child: Text(
          module.emptyMessage ?? tr.empty,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
        ),
      );
    }
    final items = module.items.take(maxCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, item) in items.indexed) ...[
          if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: colorScheme.outlineVariant),
          _GuideItemTile(item),
        ],
        sizedBoxW4H4,
      ],
    );
  }
}

/// One thread row: title (highlighted ones in the error color like the red titles on the page), the forum chip and
/// the module specific extra text (participants / time) on the right of the second line.
class _GuideItemTile extends StatelessWidget {
  const _GuideItemTile(this.item);

  final GuideItem item;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final forumName = item.forumName;
    final extra = item.extra;
    return InkWell(
      onTap: () async => context.pushNamed(
        ScreenPaths.threadV1,
        queryParameters: {'tid': item.tid, 'appBarTitle': item.title},
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyLarge?.copyWith(
                color: item.highlighted ? colorScheme.error : null,
                fontWeight: item.highlighted ? FontWeight.bold : FontWeight.w500,
                height: 1.45,
              ),
            ),
            sizedBoxW4H4,
            Row(
              children: [
                if (forumName != null) _ForumChip(name: forumName, fid: item.fid),
                if (isThreadReplied(context, item.tid)) ...[
                  sizedBoxW4H4,
                  Icon(Icons.reply_outlined, size: 14, color: colorScheme.outline),
                ],
                const Spacer(),
                if (extra != null)
                  Text(extra, style: textTheme.bodySmall?.copyWith(color: colorScheme.outline), maxLines: 1),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small forum name tag; opens the forum when its id is known.
class _ForumChip extends StatelessWidget {
  const _ForumChip({required this.name, required this.fid});

  final String name;
  final String? fid;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fid = this.fid;
    return Flexible(
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: fid == null
            ? null
            : () async => context.pushNamed(
                ScreenPaths.forum,
                pathParameters: {'fid': fid},
                queryParameters: {'appBarTitle': name},
              ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(6)),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colorScheme.onSecondaryContainer),
          ),
        ),
      ),
    );
  }
}
