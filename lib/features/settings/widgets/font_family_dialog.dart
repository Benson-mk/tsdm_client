import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Dialog for choosing font family.
class FontFamilyDialog extends StatefulWidget {
  /// Constructor.
  const FontFamilyDialog(this.initialFont, {super.key});

  /// Initial font family
  final String initialFont;

  @override
  State<FontFamilyDialog> createState() => _FontFamilyDialogState();
}

class _FontFamilyDialogState extends State<FontFamilyDialog> {
  late TextEditingController _fontController;

  @override
  void initState() {
    super.initState();
    _fontController = TextEditingController(text: widget.initialFont);
  }

  @override
  void dispose() {
    _fontController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.fontFamily;
    final textTheme = Theme.of(context).textTheme;
    final font = _fontController.text.trim();
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.font_download_outlined, title: tr.dialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // Room for the floating label of the filled field.
            padding: edgeInsetsT4,
            child: TextField(
              controller: _fontController,
              autofocus: true,
              decoration: appFieldDecoration(label: tr.title, icon: Icons.text_fields_outlined),
              onChanged: (_) => setState(() {}),
            ),
          ),
          sizedBoxW12H12,
          // Preview of the typed family; an unknown family falls back to the default font like the app does.
          AppInsetBlock(
            outlined: true,
            padding: edgeInsetsL12T12R12B12,
            child: Text(
              '${context.t.appName}\nAa Bb Cc 0123',
              style: textTheme.titleMedium?.copyWith(fontFamily: font.isEmpty ? null : font),
            ),
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.restart_alt_outlined),
          label: Text(context.t.general.reset),
          onPressed: () => context.pop(''),
        ),
        FilledButton(child: Text(context.t.general.ok), onPressed: () => context.pop(_fontController.text)),
      ],
    );
  }
}
