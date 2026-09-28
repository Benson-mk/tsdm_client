import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Card to display code block, from html node type <div class="blockcode">.
class CodeCard extends StatelessWidget {
  /// Constructor.
  const CodeCard({required this.code, this.elevation, super.key});

  /// Code text to show.
  final String code;

  /// Nesting elevation given by the HTML renderer; a nested block gets a higher surface container, no shadow.
  final double? elevation;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Code sits in its own darker block under the header; copy stays one tap away in the header.
    return AppEmbedCard(
      icon: Icons.code_outlined,
      title: context.t.codeCard.title,
      color: appEmbedColor(context, elevation),
      // An icon button: keeps the header from overflowing with large text or long translations.
      trailing: IconButton(
        icon: const Icon(Icons.copy_outlined),
        tooltip: context.t.codeCard.copy,
        onPressed: () async => copyToClipboard(context, code),
      ),
      child: SizedBox(
        width: double.infinity,
        child: AppInsetBlock(
          color: colorScheme.surfaceContainerHighest,
          padding: edgeInsetsL12T12R12B12,
          child: Text(code, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    );
  }
}
