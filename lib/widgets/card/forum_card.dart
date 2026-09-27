import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

/// Card to show forum information.
///
/// Header (icon, name, time of the latest thread), counters as pills, then the optional shortcuts (latest thread,
/// links and sub forums) in inner blocks.
class ForumCard extends StatefulWidget {
  /// Constructor.
  const ForumCard(this.forum, {super.key});

  /// Forum id.
  final Forum forum;

  @override
  State<ForumCard> createState() => _ForumCardState();
}

final class _ForumCardState extends State<ForumCard> with LoggerMixin {
  bool showingSubThread = false;
  bool showingSubForum = false;

  Future<void> _openUrl(String? url) async {
    final target = url?.parseUrlToRoute();
    if (target == null) {
      error('invalid forum card url: $url');
      return;
    }
    await context.pushNamed(
      target.screenPath,
      pathParameters: target.pathParameters,
      queryParameters: target.queryParameters,
    );
  }

  Widget _buildShortcut(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.forum.isExpanded && (widget.forum.latestThreadTitle?.isNotEmpty ?? false)) ...[
          sizedBoxW8H8,
          // Latest thread: an inner block, title on the start, author on the end.
          Material(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(appInnerRadius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () async => _openUrl(widget.forum.latestThreadUrl),
              child: Padding(
                padding: edgeInsetsL12T8R12B8,
                child: Row(
                  children: [
                    Icon(Icons.subdirectory_arrow_right_outlined, size: 16, color: colorScheme.outline),
                    sizedBoxW8H8,
                    Expanded(
                      child: Text(
                        widget.forum.latestThreadTitle ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium,
                      ),
                    ),
                    if (widget.forum.latestThreadUserName?.isNotEmpty ?? false) ...[
                      sizedBoxW8H8,
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          widget.forum.latestThreadUserName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
        if (widget.forum.subThreadList?.isNotEmpty ?? false)
          ..._buildWrapSection(context, context.t.forumCard.links, widget.forum.subThreadList!, showingSubThread, () {
            setState(() {
              showingSubThread = !showingSubThread;
            });
          }),
        if (widget.forum.subForumList?.isNotEmpty ?? false)
          ..._buildWrapSection(context, context.t.forumCard.subForums, widget.forum.subForumList!, showingSubForum, () {
            setState(() {
              showingSubForum = !showingSubForum;
            });
          }),
      ],
    );
  }

  List<Widget> _buildWrapSection(
    BuildContext context,
    String title,
    List<(String, String)> dataList,
    bool state,
    VoidCallback onPressed,
  ) {
    final wrapChildren = dataList
        .map(
          (e) => ActionChip(
            label: Text(e.$1),
            labelStyle: Theme.of(context).textTheme.labelSmall,
            visualDensity: VisualDensity.compact,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
            onPressed: () async => _openUrl(e.$2),
          ),
        )
        .toList();

    return [
      sizedBoxW4H4,
      // Collapsible section: title with the number of entries and the expand mark.
      InkWell(
        borderRadius: BorderRadius.circular(appInnerRadius),
        onTap: onPressed,
        child: Padding(
          padding: edgeInsetsT4B4,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$title (${dataList.length})',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Icon(state ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
      ),
      if (state)
        Padding(
          padding: edgeInsetsT4B4,
          child: Wrap(spacing: 8, runSpacing: 8, children: wrapChildren),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final settingsStream = getIt.get<SettingsRepository>().settings;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final tr = context.t.topicPage;

    return AppSurface(
      padding: edgeInsetsL12T12R12B12,
      onTap: () async {
        await context.pushNamed(
          ScreenPaths.forum,
          pathParameters: <String, String>{'fid': '${widget.forum.forumID}'},
          queryParameters: {'appBarTitle': widget.forum.name},
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(appInnerRadius),
                child: SizedBox(width: 88, height: 44, child: NetworkIndicatorImage(widget.forum.iconUrl)),
              ),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.forum.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (widget.forum.latestThreadTime != null)
                      Text(
                        widget.forum.latestThreadTime!.elapsedTillNow(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.secondary),
                      ),
                  ],
                ),
              ),
            ],
          ),
          sizedBoxW12H12,
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              AppInfoPill(
                icon: Icons.forum_outlined,
                label: '${widget.forum.threadCount}',
                tooltip: '${tr.threads}${widget.forum.threadCount}',
              ),
              AppInfoPill(
                icon: Icons.chat_outlined,
                label: '${widget.forum.replyCount}',
                tooltip: '${tr.posts}${widget.forum.replyCount}',
              ),
              AppInfoPill(
                icon: Icons.mark_chat_unread_outlined,
                label: '${widget.forum.threadTodayCount ?? 0}',
                tooltip: '${tr.today}${widget.forum.threadTodayCount ?? 0}',
              ),
            ],
          ),
          StreamBuilder(
            stream: settingsStream,
            builder: (context, settings) {
              if (!settings.hasData) {
                return const SizedBox.shrink();
              }
              if (settings.data!.showShortcutInForumCard) {
                return _buildShortcut(context);
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }
}
