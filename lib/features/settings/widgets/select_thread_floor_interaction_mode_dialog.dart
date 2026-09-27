import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/thread_floor_interaction_mode.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// Show a dialog to let user select the interaction mode of floors in thread pages.
Future<ThreadFloorInteractionMode?> showSelectThreadFloorInteractionMode(
  BuildContext context,
  ThreadFloorInteractionMode initialMode,
) async => showDialog<ThreadFloorInteractionMode>(
  context: context,
  builder: (context) =>
      RootPage(DialogPaths.selectThreadFloorInteractionMode, _SelectThreadFloorInteractionModeDialog(initialMode)),
);

class _SelectThreadFloorInteractionModeDialog extends StatelessWidget {
  const _SelectThreadFloorInteractionModeDialog(this.initialMode);

  final ThreadFloorInteractionMode initialMode;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.behaviorSection.threadFloorInteractionMode;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.touch_app_outlined, title: tr.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: edgeInsetsL24R24.add(const EdgeInsets.only(bottom: 8)),
            child: Text(
              tr.detail,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          SelectableListTile(
            leading: initialMode == ThreadFloorInteractionMode.adaptiveTapMenu ? null : const Icon(Icons.menu_open),
            title: Text(tr.adaptiveTapOpenContextMenu),
            selected: initialMode == ThreadFloorInteractionMode.adaptiveTapMenu,
            onTap: () => context.pop(ThreadFloorInteractionMode.adaptiveTapMenu),
          ),
          SelectableListTile(
            leading: initialMode == ThreadFloorInteractionMode.tapToReply ? null : const Icon(Icons.reply_outlined),
            title: Text(tr.tapToReply),
            selected: initialMode == ThreadFloorInteractionMode.tapToReply,
            onTap: () => context.pop(ThreadFloorInteractionMode.tapToReply),
          ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
