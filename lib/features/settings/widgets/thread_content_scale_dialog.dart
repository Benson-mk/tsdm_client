import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Lower bound of the extra thread content scale: no extra scale.
const threadContentScaleMin = 1.0;

/// Upper bound of the extra thread content scale.
const threadContentScaleMax = 2.0;

/// Dialog to pick the extra text scale applied to floors in thread page (GitHub #137).
class ThreadContentScaleDialog extends StatefulWidget {
  /// Constructor.
  const ThreadContentScaleDialog(this.initialScale, {super.key});

  /// Thread content scale when enter this widget.
  final double initialScale;

  @override
  State<ThreadContentScaleDialog> createState() => _ThreadContentScaleDialogState();
}

class _ThreadContentScaleDialogState extends State<ThreadContentScaleDialog> {
  late double _currentScale;

  @override
  void initState() {
    super.initState();
    _currentScale = widget.initialScale.clamp(threadContentScaleMin, threadContentScaleMax);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.threadContentScale;

    return CustomAlertDialog.sync(
      title: Text(tr.dialogTitle),
      content: Column(
        spacing: 12,
        children: [
          Text(_currentScale.toString()),
          Slider(
            autofocus: true,
            // Since flutter 3.29
            // ignore: deprecated_member_use
            year2023: false,
            min: threadContentScaleMin,
            max: threadContentScaleMax,
            divisions: 10,
            value: _currentScale,
            onChanged: (v) => setState(() => _currentScale = double.parse(v.toStringAsFixed(1))),
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => context.pop(_currentScale), child: Text(context.t.general.ok))],
    );
  }
}
