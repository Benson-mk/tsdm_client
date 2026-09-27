import 'dart:math';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Widget to show some quoted text.
class QuotedText extends StatelessWidget {
  /// Construct from [String] [text].
  const QuotedText(this.text, {super.key}) : span = null;

  /// Construct from an [InlineSpan] span.
  const QuotedText.rich(this.span, {super.key}) : text = null;

  /// Text to show in quoted style.
  final String? text;

  /// Span to show in quoted style.
  final InlineSpan? span;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final quotedColor = colorScheme.tertiary;
    final quotedStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant);

    final Widget content;
    if (text != null) {
      content = Text(text!, style: quotedStyle);
    } else if (span != null) {
      content = Text.rich(TextSpan(style: quotedStyle, children: [span!]));
    } else {
      // Impossible.
      return const SizedBox.shrink();
    }

    // A tinted block with an accent bar on the start side and one opening quote mark: reads as quoted without the
    // large quote icons around the text. The rich content (links, images, emojis) keeps its own styles.
    return ClipRRect(
      borderRadius: BorderRadius.circular(appInnerRadius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.tertiaryContainer.withValues(alpha: 0.35),
          border: Border(left: BorderSide(color: quotedColor, width: 3)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Transform.rotate(
                angle: pi,
                child: Icon(Icons.format_quote_rounded, size: 18, color: quotedColor),
              ),
              sizedBoxW8H8,
              Expanded(child: content),
            ],
          ),
        ),
      ),
    );
  }
}
