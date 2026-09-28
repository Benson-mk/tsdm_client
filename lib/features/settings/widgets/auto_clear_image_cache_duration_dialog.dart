import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/settings/widgets/auto_sync_notice_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Dialog for user select a duration for image cache considered outdated till last used time.
class AutoClearImageCacheDurationDialog extends StatefulWidget {
  /// Constructor.
  const AutoClearImageCacheDurationDialog(this.currentSeconds, {super.key});

  /// Current duration in seconds.
  final int currentSeconds;

  @override
  State<AutoClearImageCacheDurationDialog> createState() => _AutoClearImageCacheDurationDialogState();
}

class _AutoClearImageCacheDurationDialogState extends State<AutoClearImageCacheDurationDialog> {
  late double _choiceIndex;

  static const List<int> allTimes = [
    // 6 hours
    3600 * 6,

    // 12 hours
    3600 * 12,

    // 1 days
    3600 * 24 * 1,

    // 3 days
    3600 * 24 * 3,

    // 7 days
    3600 * 24 * 7,

    // 15 days
    3600 * 24 * 15,

    // 30 days
    3600 * 24 * 30,
  ];

  @override
  void initState() {
    super.initState();
    // The default value of the setting is a duration in seconds, not an index: look it up, and fall back to the
    // 7 days choice when it is not one of the choices either.
    final defaultIndex = allTimes.indexOf(SettingsKeys.autoClearImageCacheDuration.defaultValue);
    _choiceIndex = allTimes.contains(widget.currentSeconds)
        ? allTimes.indexOf(widget.currentSeconds).toDouble()
        : (defaultIndex >= 0 ? defaultIndex : allTimes.indexOf(3600 * 24 * 7)).toDouble();
  }

  String _timeText(BuildContext context, int time) => switch (time) {
    < 0 => context.t.general.never,
    >= 0 && < 3600 => context.t.general.minutes(value: time ~/ 60),
    >= 3600 && < 3600 * 24 => context.t.general.hours(value: time ~/ 3600),
    _ => context.t.general.days(value: time ~/ (3600 * 24)),
  };

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.storageSection.scheduledCleaning;

    final time = allTimes[_choiceIndex.toInt()];

    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.auto_delete_outlined, title: tr.duration.title),
      content: SettingsDurationSliderBody(
        description: tr.duration.detail,
        valueText: _timeText(context, time),
        firstText: _timeText(context, allTimes.first),
        lastText: _timeText(context, allTimes.last),
        index: _choiceIndex,
        count: allTimes.length,
        onChanged: (v) => setState(() => _choiceIndex = v),
      ),
      actions: [
        FilledButton(child: Text(context.t.general.ok), onPressed: () => context.pop(allTimes[_choiceIndex.toInt()])),
      ],
    );
  }
}
