import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/settings/widgets/auto_sync_notice_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Dialog to choose how many threads the offline copies are kept for; pops the chosen number.
class OfflineThreadsLimitDialog extends StatefulWidget {
  /// Constructor.
  const OfflineThreadsLimitDialog(this.current, {super.key});

  /// The limit set now.
  final int current;

  /// The numbers offered.
  static const List<int> choices = [10, 20, 50, 100, 200, 500];

  @override
  State<OfflineThreadsLimitDialog> createState() => _OfflineThreadsLimitDialogState();
}

class _OfflineThreadsLimitDialogState extends State<OfflineThreadsLimitDialog> {
  late double _index;

  static const List<int> _choices = OfflineThreadsLimitDialog.choices;

  @override
  void initState() {
    super.initState();
    final current = _choices.indexOf(widget.current);
    _index = (current >= 0 ? current : _choices.indexOf(SettingsKeys.offlineThreadsLimit.defaultValue)).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.storageSection.offlineThreads.limit;
    final value = _choices[_index.toInt()];
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.cloud_download_outlined, title: tr.title),
      content: SettingsDurationSliderBody(
        description: tr.detail,
        valueText: tr.value(count: value),
        firstText: '${_choices.first}',
        lastText: '${_choices.last}',
        index: _index,
        count: _choices.length,
        onChanged: (v) => setState(() => _index = v),
      ),
      actions: [FilledButton(child: Text(context.t.general.ok), onPressed: () => context.pop(value))],
    );
  }
}
