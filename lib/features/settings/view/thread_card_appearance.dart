import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// Settings page for thread card appearance
class SettingsThreadCardAppearancePage extends StatefulWidget {
  /// Constructor.
  const SettingsThreadCardAppearancePage({super.key});

  @override
  State<SettingsThreadCardAppearancePage> createState() => _SettingsThreadCardAppearancePageState();
}

class _SettingsThreadCardAppearancePageState extends State<SettingsThreadCardAppearancePage> {
  Future<void> showHelpDialog(BuildContext context) async {
    final tr = context.t.settingsPage.appearanceSection.threadCard.attrs;

    final items = <(IconData, String, String)>[
      for (final threadState in ThreadStateModel.values)
        switch (threadState) {
          ThreadStateModel.closed => (threadState.icon, tr.closed.title, tr.closed.detail),
          ThreadStateModel.upVoted => (threadState.icon, tr.upVoted.title, tr.upVoted.detail),
          ThreadStateModel.pictureAttached => (threadState.icon, tr.pictureAttached.title, tr.pictureAttached.detail),
          ThreadStateModel.digested => (threadState.icon, tr.digested.title, tr.digested.detail),
          ThreadStateModel.pinnedGlobally => (threadState.icon, tr.pinnedGlobally.title, tr.pinnedGlobally.detail),
          ThreadStateModel.pinnedInType => (threadState.icon, tr.pinnedInType.title, tr.pinnedInType.detail),
          ThreadStateModel.pinnedInSubreddit => (
            threadState.icon,
            tr.pinnedInSubreddit.title,
            tr.pinnedInSubreddit.detail,
          ),
          ThreadStateModel.poll => (threadState.icon, tr.vote.title, tr.vote.detail),
          ThreadStateModel.rewarded => (threadState.icon, tr.rewarded.title, tr.rewarded.detail),
          ThreadStateModel.draft => (threadState.icon, tr.draft.title, tr.draft.detail),
        },
    ];

    await showDialog<void>(
      context: context,
      builder: (context) {
        final textTheme = Theme.of(context).textTheme;
        final colorScheme = Theme.of(context).colorScheme;
        return RootPage(
          DialogPaths.threadCardHelp,
          CustomAlertDialog.sync(
            title: AppDialogTitle(icon: Icons.help_outline, title: tr.help),
            // One row per mark: the icon as it appears on the card, its name and what it means.
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (icon, title, detail) in items)
                  Padding(
                    padding: edgeInsetsT4B4,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppIconTile(icon, size: 32),
                        sizedBoxW12H12,
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                              Text(detail, style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildExample(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.threadCard.example;
    final someTime = DateTime.fromMillisecondsSinceEpoch(int.parse(tr.time));
    return NormalThreadCard(
      NormalThread(
        title: tr.title,
        url: '',
        // Not used
        threadID: '114514',
        author: User(
          name: tr.author,
          url: '', // Not used
        ),
        publishDate: someTime,
        latestReplyAuthor: User(
          name: tr.lastReplyAuthor,
          url: '', // Not used
        ),
        latestReplyTime: DateTime.now().add(const Duration(minutes: -1)),
        iconUrl: '',
        // Not used
        threadType: ThreadType(
          name: tr.threadType,
          url: '', // Not used
        ),
        viewCount: int.parse(tr.view),
        replyCount: int.parse(tr.reply),
        price: null,
        privilege: 0,
        css: null,
        stateSet: {ThreadStateModel.pinnedGlobally, ThreadStateModel.digested},
        isRecentThread: true,
      ),
      disableTap: true,
    );
  }

  /// The example card in a tinted block with its header, so it reads as a preview and not as a real thread.
  Widget _buildPreview(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.threadCard;
    return AppInsetBlock(
      outlined: true,
      padding: edgeInsetsL12T4R12B12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppSectionHeader(tr.preview, icon: Icons.preview_outlined),
          _buildExample(context),
        ],
      ),
    );
  }

  Widget _buildOptions(BuildContext context, SettingsMap settings) {
    final tr = context.t.settingsPage.appearanceSection.threadCard;
    return AppTileGroup(
      title: tr.title,
      icon: Icons.tune_outlined,
      children: [
        SectionSwitchListTile(
          secondary: const Icon(Icons.format_align_center_outlined),
          title: Text(tr.infoRowAlignCenter),
          value: settings.threadCardInfoRowAlignCenter,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadCardInfoRowAlignCenter, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.person_pin_outlined),
          title: Text(tr.showLastReplyAuthor),
          value: settings.threadCardShowLastReplyAuthor,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadCardShowLastReplyAuthor, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.new_releases_outlined),
          title: Text(tr.highlightRecentThread),
          value: settings.threadCardHighlightRecentThread,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadCardHighlightRecentThread, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.badge_outlined),
          title: Text(tr.highlightAuthorName),
          value: settings.threadCardHighlightAuthorName,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadCardHighlightAuthorName, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.highlight_outlined),
          title: Text(tr.highlightInfoRow),
          value: settings.threadCardHighlightInfoRow,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadCardHighlightInfoRow, v)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.threadCard;
    final settings = context.watch<SettingsBloc>().state.settingsMap;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: tr.showHelpTip,
            onPressed: () async => showHelpDialog(context),
          ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= appTwoColumnWidth;
            final padding = appCenteredPadding(
              constraints.maxWidth,
              maxWidth: wide ? appListMaxWidth : appFormMaxWidth,
            ).copyWith(top: 12, bottom: 24 + MediaQuery.paddingOf(context).bottom);
            // Wide windows: preview and switches side by side, the preview stays in view while toggling.
            // Phones: the preview first, the switches under it, one scroll view (landscape and large text fit).
            return ListView(
              padding: padding,
              children: [
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildPreview(context)),
                      const SizedBox(width: appSurfaceGap),
                      Expanded(child: _buildOptions(context, settings)),
                    ],
                  )
                else ...[
                  _buildPreview(context),
                  const SizedBox(height: appSurfaceGap),
                  _buildOptions(context, settings),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
