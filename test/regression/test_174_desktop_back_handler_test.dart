import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/widgets/desktop_back_handler.dart';

/// GitHub #138: on desktop, `Esc` and the mouse back button go back one page, and only when that is what a user
/// would expect: never from the root page, never out of a text input, and dialogs or persistent sheets close first.
void main() {
  setUp(() => DesktopBackHandler.enabledOverride = true);
  tearDown(() => DesktopBackHandler.enabledOverride = null);

  /// Number of times the root page refused a pop.
  var rootPopAttempts = 0;

  Widget app({bool secondCanPop = true, ValueChanged<bool>? onSecondPopInvoked}) => MaterialApp(
    builder: (context, child) => DesktopBackHandler(child: child ?? const SizedBox.shrink()),
    home: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => rootPopAttempts++,
      child: Scaffold(
        appBar: AppBar(title: const Text('Root')),
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PopScope(
                  canPop: secondCanPop,
                  onPopInvokedWithResult: (didPop, _) => onSecondPopInvoked?.call(didPop),
                  child: Scaffold(
                    appBar: AppBar(title: const Text('Second')),
                    body: Builder(
                      builder: (context) => Column(
                        children: [
                          const TextField(key: Key('field')),
                          TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => const AlertDialog(title: Text('Dialog')),
                            ),
                            child: const Text('dialog'),
                          ),
                          TextButton(
                            onPressed: () => Scaffold.of(context).showBottomSheet(
                              (_) => const SizedBox(height: 100, child: Text('Sheet')),
                            ),
                            child: const Text('sheet'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('push'),
          ),
        ),
      ),
    ),
  );

  Future<void> pushSecond(WidgetTester tester) async {
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
  }

  Future<void> escape(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  Future<void> mouseBack(WidgetTester tester) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse, null, kBackMouseButton);
    await tester.sendEventToBinding(pointer.down(tester.getCenter(find.byType(Scaffold).last)));
    await tester.sendEventToBinding(pointer.up());
    await tester.pumpAndSettle();
  }

  setUp(() => rootPopAttempts = 0);

  testWidgets('Esc and the mouse back button pop a page that can go back', (tester) async {
    await tester.pumpWidget(app());
    await pushSecond(tester);
    await escape(tester);
    expect(find.text('Second'), findsNothing);
    expect(find.text('Root'), findsOneWidget);

    await pushSecond(tester);
    await mouseBack(tester);
    expect(find.text('Second'), findsNothing);
    expect(find.text('Root'), findsOneWidget);
    expect(rootPopAttempts, 0);
  });

  testWidgets('nothing happens on the root page', (tester) async {
    await tester.pumpWidget(app());
    await escape(tester);
    await mouseBack(tester);
    expect(find.text('Root'), findsOneWidget);
    expect(rootPopAttempts, 0, reason: 'the exit-app PopScope of the root page is never poked');
  });

  testWidgets('a focused text input keeps Esc and the mouse back button', (tester) async {
    await tester.pumpWidget(app());
    await pushSecond(tester);
    await tester.tap(find.byKey(const Key('field')));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(isA<FocusScope>()));

    await escape(tester);
    expect(find.text('Second'), findsOneWidget);
    await mouseBack(tester);
    expect(find.text('Second'), findsOneWidget);
    expect(rootPopAttempts, 0);
  });

  testWidgets('Esc closes an open dialog first and the page only afterwards', (tester) async {
    await tester.pumpWidget(app());
    await pushSecond(tester);
    await tester.tap(find.text('dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Dialog'), findsOneWidget);

    await escape(tester);
    expect(find.text('Dialog'), findsNothing);
    expect(find.text('Second'), findsOneWidget);

    await escape(tester);
    expect(find.text('Second'), findsNothing);
  });

  testWidgets('a persistent bottom sheet closes before the page', (tester) async {
    await tester.pumpWidget(app());
    await pushSecond(tester);
    await tester.tap(find.text('sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet'), findsOneWidget);

    await escape(tester);
    expect(find.text('Sheet'), findsNothing);
    expect(find.text('Second'), findsOneWidget);

    await mouseBack(tester);
    expect(find.text('Second'), findsNothing);
  });

  testWidgets('a page refusing to pop keeps deciding through its PopScope', (tester) async {
    final invocations = <bool>[];
    await tester.pumpWidget(app(secondCanPop: false, onSecondPopInvoked: invocations.add));
    await pushSecond(tester);
    await escape(tester);
    expect(find.text('Second'), findsOneWidget);
    expect(invocations, [false]);
  });

  testWidgets('disabled outside desktop', (tester) async {
    DesktopBackHandler.enabledOverride = false;
    await tester.pumpWidget(app());
    await pushSecond(tester);
    await escape(tester);
    await mouseBack(tester);
    expect(find.text('Second'), findsOneWidget);
  });
}
