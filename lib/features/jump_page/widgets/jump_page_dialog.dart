import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// A dialog to ask jump page info from user before jump page.
class JumpPageDialog extends StatefulWidget {
  /// Constructor.
  const JumpPageDialog({required this.current, required this.max, this.min = 0, super.key})
    : assert(max >= min, 'max index should be not less than min'),
      assert(current > 0, 'current page index should be large than 0'),
      assert(min <= current, 'current should larger than min'),
      assert(current <= max, 'current should no more than max');

  /// Current page number.
  final int current;

  /// Minimum page number.
  final int min;

  /// Maximum page number.
  final int max;

  @override
  State<JumpPageDialog> createState() => _JumpPageDialogState();
}

class _JumpPageDialogState extends State<JumpPageDialog> {
  late int currentPage;
  late final TextEditingController textController;

  @override
  void initState() {
    super.initState();
    currentPage = widget.current;
    textController = TextEditingController(text: '$currentPage');
  }

  @override
  void dispose() {
    super.dispose();
    textController.dispose();
  }

  /// Select [page], kept within the pages of the thread.
  void _select(int page) => setState(() {
    currentPage = page.clamp(widget.min, widget.max);
    textController.text = '$currentPage';
  });

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final atStart = currentPage <= math.max(widget.min, 1);
    final atEnd = currentPage >= widget.max;
    return CustomAlertDialog.sync(
      title: Text(context.t.jumpDialog.title),
      content: Column(
        children: [
          // Quick steps: first, previous, next and last page, with the platform's own tooltips.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.first_page),
                tooltip: localizations.firstPageTooltip,
                onPressed: atStart ? null : () => _select(math.max(widget.min, 1)),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: localizations.previousPageTooltip,
                onPressed: atStart ? null : () => _select(currentPage - 1),
              ),
              Flexible(
                child: Padding(
                  padding: edgeInsetsL8R8,
                  child: Text(
                    '$currentPage / ${widget.max}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: localizations.nextPageTooltip,
                onPressed: atEnd ? null : () => _select(currentPage + 1),
              ),
              IconButton(
                icon: const Icon(Icons.last_page),
                tooltip: localizations.lastPageTooltip,
                onPressed: atEnd ? null : () => _select(widget.max),
              ),
            ],
          ),
          Slider(
            autofocus: true,
            // Since flutter 3.29
            // ignore: deprecated_member_use
            year2023: false,
            max: widget.max.toDouble(),
            min: widget.min.toDouble(),
            divisions: math.max(widget.max - 1, 1),
            label: '$currentPage',
            value: currentPage.toDouble(),
            onChanged: (v) => setState(() {
              currentPage = v.round();
              textController.text = currentPage.toString();
            }),
          ),
          sizedBoxW12H12,
          TextField(
            controller: textController,
            decoration: const InputDecoration(
              border: UnderlineInputBorder(),
              constraints: BoxConstraints(maxWidth: 100),
            ),
            textAlign: TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter(RegExp(r'\d'), allow: true)],
            keyboardType: TextInputType.number,
            onChanged: (v) {
              final vv = int.tryParse(v);
              if (vv == null || vv < widget.min || vv > widget.max) {
                return;
              }
              setState(() => currentPage = vv);
            },
          ),
        ],
      ),
      actions: [
        TextButton(child: Text(context.t.general.cancel), onPressed: () => context.pop()),
        TextButton(
          child: Text(context.t.general.ok),
          onPressed: () {
            if (currentPage != widget.current) {
              // Page changed.
              context.pop(currentPage);
            } else {
              context.pop();
            }
          },
        ),
      ],
    );
  }
}
