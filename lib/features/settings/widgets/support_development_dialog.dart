import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

final _featureRequestUri = Uri.https('github.com', '/Carinoasd/tsdm_client/issues/new', {
  'template': '02_feedback.yml',
});

/// Voluntary donations and feature requests, opened explicitly by the user.
class SupportDevelopmentDialog extends StatefulWidget {
  /// Constructor.
  const SupportDevelopmentDialog({super.key});

  /// Original donation image, bundled so it can also be viewed offline.
  static const imagePath = 'assets/images/alipay-donation.jpg';

  @override
  State<SupportDevelopmentDialog> createState() => _SupportDevelopmentDialogState();
}

class _SupportDevelopmentDialogState extends State<SupportDevelopmentDialog> with LoggerMixin {
  bool _saving = false;
  bool _openingRequest = false;
  bool _requestOpenFailed = false;

  Future<void> _openFeatureRequest() async {
    if (_openingRequest) {
      return;
    }
    setState(() {
      _openingRequest = true;
      _requestOpenFailed = false;
    });
    var opened = false;
    try {
      opened = await openInExternalBrowser(_featureRequestUri);
    } on Object catch (e, st) {
      handleRaw(e, st);
    } finally {
      if (mounted) {
        setState(() {
          _openingRequest = false;
          _requestOpenFailed = !opened;
        });
      }
    }
  }

  Future<void> _saveImage() async {
    if (_saving) {
      return;
    }
    final tr = context.t.aboutPage;
    setState(() => _saving = true);
    try {
      final asset = await rootBundle.load(SupportDevelopmentDialog.imagePath);
      final bytes = asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: tr.saveDonationCode,
        fileName: 'tsdm-client-alipay.jpg',
        type: FileType.custom,
        allowedExtensions: ['jpg'],
        bytes: isDesktop ? null : bytes,
      );
      if (path == null) {
        return;
      }
      if (isDesktop) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (mounted) {
        showSnackBar(context: context, message: tr.donationCodeSaved);
      }
    } on Object catch (e, st) {
      handleRaw(e, st);
      if (mounted) {
        showSnackBar(context: context, message: tr.donationCodeSaveFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.aboutPage;
    final colorScheme = Theme.of(context).colorScheme;
    final mutedStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant);
    // Same texts, order and actions as before; only grouped: the voluntary nature first, then the feature request
    // block, then the donation code on a white ground so it stays scannable in the dark theme.
    return AlertDialog(
      // One line: the longer name wrapped to two lines on a narrow phone (feedback on 1.29.1).
      title: AppDialogTitle(icon: Icons.volunteer_activism_outlined, title: tr.supportDevelopment, singleLine: true),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr.donationDescription, style: mutedStyle),
            const SizedBox(height: 16),
            AppInsetBlock(
              outlined: true,
              padding: edgeInsetsL12T4R12B12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppSectionHeader(tr.featureRequestTitle, icon: Icons.lightbulb_outline),
                  Text(tr.featureRequestDescription, style: mutedStyle),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _openingRequest ? null : _openFeatureRequest,
                    // No spinner while the browser opens: the disabled button is the pending state.
                    icon: const Icon(Icons.open_in_new),
                    label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr.featureRequestAction, maxLines: 1)),
                  ),
                  if (_requestOpenFailed) ...[
                    const SizedBox(height: 8),
                    AppNoticeBanner(message: tr.featureRequestOpenFailed, tone: AppNoticeTone.error),
                    const SizedBox(height: 4),
                    SelectableText(
                      _featureRequestUri.toString(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.primary),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            AppSectionHeader(tr.donationTitle, icon: Icons.qr_code_2_outlined),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(appInnerRadius),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(SupportDevelopmentDialog.imagePath, semanticLabel: tr.donationCodeLabel),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(tr.donationInstructions, style: mutedStyle),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _saving ? null : _saveImage,
          icon: const Icon(Icons.save_alt),
          label: Text(tr.saveDonationCode),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.close)),
      ],
    );
  }
}
