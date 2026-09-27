import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/editor/widgets/editor_frame.dart';
import 'package:tsdm_client/features/rate/widgets/fast_rate_template_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/bounty_card.dart';
import 'package:tsdm_client/widgets/card/code_card.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';

/// Full UI redesign, phase 3 (editors, reply bar, drafts, polls, rates, templates, report, reader controls, floor
/// cards): the new shared pieces fit a narrow phone with a large font, a pinned submit bar stays reachable above the
/// keyboard, and the editor frame follows the focus.
///
/// Synthetic data, no network.

/// A 320 wide phone with the text scaled to [scale], optionally with the keyboard open ([keyboard] logical pixels).
Future<void> _pumpNarrow(WidgetTester tester, Widget body, {double scale = 2, double keyboard = 0}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 560);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: Scaffold(body: body),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() async => LocaleSettings.setLocale(AppLocale.en));

  group('shared pieces on a narrow phone with a large font', () {
    testWidgets('notice banner wraps a long message with actions', (tester) async {
      await _pumpNarrow(
        tester,
        SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: AppNoticeBanner(
            tone: AppNoticeTone.error,
            title: 'Refused',
            message: 'a long forum message that has to wrap on several lines ' * 4,
            actions: [TextButton(onPressed: () {}, child: const Text('Retry'))],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Refused'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('embedded card keeps its header and trailing action, the title wraps', (tester) async {
      var tapped = 0;
      await _pumpNarrow(
        tester,
        SingleChildScrollView(
          padding: const EdgeInsets.all(6),
          child: AppEmbedCard(
            icon: Icons.poll_outlined,
            title: 'An embedded block with a long title that wraps',
            subtitle: 'ends 2026-10-01',
            trailing: IconButton(onPressed: () => tapped++, icon: const Icon(Icons.bar_chart_outlined)),
            child: const Text('body'),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.bar_chart_outlined));
      expect(tapped, 1);
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('form section and pinned submit bar stay usable with the keyboard open', (tester) async {
      var submitted = 0;
      await _pumpNarrow(
        tester,
        Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: AppFormSection(
                  title: 'Scores',
                  icon: Icons.star_rate_outlined,
                  children: [
                    for (var i = 0; i < 4; i++) TextField(decoration: InputDecoration(labelText: 'Field $i')),
                  ],
                ),
              ),
            ),
            AppBottomActionBar(
              child: FilledButton(onPressed: () => submitted++, child: const Text('Submit')),
            ),
          ],
        ),
        keyboard: 260,
      );
      expect(tester.takeException(), isNull);
      // The bar sits above the keyboard: the button is on screen and receives the tap.
      final button = tester.getRect(find.text('Submit'));
      expect(button.bottom, lessThanOrEqualTo(560 - 260));
      await tester.tap(find.text('Submit'));
      expect(submitted, 1);
    });

    testWidgets('editor control bar keeps the trailing send button with many tools', (tester) async {
      var sent = 0;
      await _pumpNarrow(
        tester,
        Align(
          alignment: Alignment.bottomCenter,
          child: EditorControlBar(
            leading: [
              for (var i = 0; i < 12; i++) IconButton(onPressed: () {}, icon: const Icon(Icons.format_bold)),
            ],
            trailing: [FilledButton(onPressed: () => sent++, child: const Icon(Icons.send))],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.send));
      expect(sent, 1);
    });

    testWidgets('editor frame border follows the focus of the editor', (tester) async {
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await _pumpNarrow(
        tester,
        Padding(
          padding: const EdgeInsets.all(12),
          child: EditorFrame(
            focusNode: focusNode,
            child: TextField(focusNode: focusNode),
          ),
        ),
        scale: 1,
      );
      Color border() {
        final box = tester.widget<DecoratedBox>(
          find.descendant(of: find.byType(EditorFrame), matching: find.byType(DecoratedBox)).first,
        );
        return ((box.decoration as BoxDecoration).border! as Border).top.color;
      }

      final primary = Theme.of(tester.element(find.byType(EditorFrame))).colorScheme.primary;
      final outlineVariant = Theme.of(tester.element(find.byType(EditorFrame))).colorScheme.outlineVariant;
      expect(border(), outlineVariant);

      // requestFocus applies the change in a microtask and schedules no frame by itself: the first pump only flushes
      // that microtask (the node notifies, the frame is marked dirty), the second pump builds the frame. In the app a
      // tap or the editor opening always leads to that next frame.
      focusNode.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(border(), primary);

      focusNode.unfocus();
      await tester.pump();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);
      expect(border(), outlineVariant);
    });
  });

  group('floor cards and quotes', () {
    testWidgets('code card, bounty card and a quote fit a narrow phone with a large font', (tester) async {
      await _pumpNarrow(
        tester,
        SingleChildScrollView(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              CodeCard(code: 'final value = compute(input); // ' * 4),
              const BountyCard(resolved: false, price: '100'),
              const QuotedText('a quoted reply that is long enough to wrap on a phone'),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(CodeCard), findsOneWidget);
      expect(find.textContaining('a quoted reply'), findsOneWidget);
    });

    testWidgets('rate score chips keep the sign of the value', (tester) async {
      await _pumpNarrow(
        tester,
        const Wrap(
          children: [
            RateScoreChip(name: 'A', value: 3),
            RateScoreChip(name: 'B', value: -2),
            RateScoreChip(name: 'C', value: 0),
          ],
        ),
        scale: 1,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(RateScoreChip), findsNWidgets(3));
      expect(
        tester.widgetList<RichText>(find.byType(RichText)).map((e) => e.text.toPlainText()),
        containsAll(<String>['A +3', 'B -2', 'C 0']),
      );
    });

    testWidgets('a blocked floor keeps its number and one action on a narrow phone', (tester) async {
      await _pumpNarrow(
        tester,
        const Padding(
          padding: EdgeInsets.all(6),
          child: BlockedPostPlaceholder(uid: 1001, username: 'Bob', floor: 42),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('#42'), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
    });
  });
}
