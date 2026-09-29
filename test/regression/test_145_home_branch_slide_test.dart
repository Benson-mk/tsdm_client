import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';

/// Regression test of the shell branch slide (#145).
///
/// The bottom navigation tabs switch through [AnimatedBranchPageView], which hosts the branches in a [PageView]: the
/// switch animates instead of jumping, and every branch has to stay mounted so its page state survives — the
/// `indexedStack` route it replaced kept all of them alive.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pump a two-branch shell that uses the same container as the app.
  Future<void> pumpShell(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/a',
      routes: [
        StatefulShellRoute(
          builder: (context, state, navigationShell) => Scaffold(
            body: navigationShell,
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: navigationShell.currentIndex,
              onTap: (index) => navigationShell.goBranch(index),
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'tab-a'),
                BottomNavigationBarItem(icon: Icon(Icons.star_outline), label: 'tab-b'),
                BottomNavigationBarItem(icon: Icon(Icons.favorite_outline), label: 'tab-c'),
              ],
            ),
          ),
          navigatorContainerBuilder: (context, navigationShell, children) =>
              AnimatedBranchPageView(navigationShell: navigationShell, children: children),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/a', builder: (_, _) => const _CounterPage(label: 'a', key: ValueKey('page-a'))),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/b', builder: (_, _) => const _CounterPage(label: 'b', key: ValueKey('page-b'))),
              ],
            ),
            // Three branches, like the app: switching to the far one is what a PageView would drop when it does not
            // keep its pages alive.
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/c', builder: (_, _) => const _CounterPage(label: 'c', key: ValueKey('page-c'))),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
  }

  /// Tap the "+1" button of the branch [label].
  Future<void> tapPlus(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byKey(ValueKey('page-$label')), matching: find.text('plus')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('switching a branch slides instead of jumping', (tester) async {
    await pumpShell(tester);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.physics, isA<NeverScrollableScrollPhysics>());
    expect(pageView.controller!.page, 0);

    await tester.tap(find.text('tab-c'));
    await tester.pumpAndSettle();

    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.text('c: 0'), findsOneWidget);
  });

  testWidgets('a branch keeps its state while a far branch is shown', (tester) async {
    await pumpShell(tester);
    await tapPlus(tester, 'a');
    expect(find.text('a: 1'), findsOneWidget);

    await tester.tap(find.text('tab-c'));
    await tester.pumpAndSettle();
    expect(find.text('c: 0'), findsOneWidget);

    await tester.tap(find.text('tab-a'));
    await tester.pumpAndSettle();

    // The first branch must not have been rebuilt from scratch by the slide.
    expect(find.text('a: 1'), findsOneWidget);
  });
}

/// A branch page with local state, so a lost branch shows up as a reset counter.
class _CounterPage extends StatefulWidget {
  const _CounterPage({required this.label, super.key});

  final String label;

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text('${widget.label}: $_count'),
      FilledButton(onPressed: () => setState(() => _count++), child: const Text('plus')),
    ],
  );
}
