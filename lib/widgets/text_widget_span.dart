import 'package:flutter/widgets.dart';

/// A [WidgetSpan] of [child], a widget with text in it (a card, a quote, a table...), placed in a paragraph that
/// follows the text scale.
///
/// The paragraph lays [child] out at its width divided by the text scale and paints it scaled up by the text scale
/// (flutter/flutter#126962), so the widget as a whole already follows the text scale. Text in it would read the same
/// text scale from [MediaQuery] and be scaled a second time: a text scale of 1.3 became 1.69, cards were crowded and
/// broke lines badly. [child] is built without a text scale of its own, it is scaled once with the paragraph.
///
/// A widget without text (an image, a divider) does not need it, it is scaled once already.
WidgetSpan textWidgetSpan(Widget child) => WidgetSpan(child: TextWidgetSpanChild(child));

/// The child of a [textWidgetSpan]: [child] built without a text scale of its own.
class TextWidgetSpanChild extends StatelessWidget {
  /// Constructor.
  const TextWidgetSpanChild(this.child, {super.key});

  /// The widget in the span.
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
    child: child,
  );
}
