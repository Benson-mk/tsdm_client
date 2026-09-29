import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';

/// Regression test of the shell branch slide (#145).
///
/// The bottom navigation tabs switch through [AnimatedBranchPageView], which hosts the branches in a [PageView]: the
/// switch animates instead of jumping, and every branch has to stay mounted so its page state survives — the
/// `indexedStack` route it replaced kept all of them alive. Staying mounted also means the hidden branches have to be
/// muted by hand, otherwise their progress indicators keep animating behind the visible one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pump a three-branch shell that uses the same container as the app.
  ///
  /// With [disableAnimations] the container receives the system "reduce motion" setting through a [MediaQuery], like
  /// the app does when the platform reports it. [ticks] makes every branch run an endless animation and counts its
  /// frames there; the shell is not settled then, because an endless animation never settles.
  Future<void> pumpShell(WidgetTester tester, {bool disableAnimations = false, Map<String, int>? ticks}) async {
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
          navigatorContainerBuilder: (context, navigationShell, children) {
            final container = AnimatedBranchPageView(navigationShell: navigationShell, children: children);
            if (!disableAnimations) {
              return container;
            }
            return MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: container);
          },
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/a',
                  builder: (_, _) => _CounterPage(label: 'a', ticks: ticks, key: const ValueKey('page-a')),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/b',
                  builder: (_, _) => _CounterPage(label: 'b', ticks: ticks, key: const ValueKey('page-b')),
                ),
              ],
            ),
            // Three branches, like the app: switching to the far one is what a PageView would drop when it does not
            // keep its pages alive.
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/c',
                  builder: (_, _) => _CounterPage(label: 'c', ticks: ticks, key: const ValueKey('page-c')),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    if (ticks == null) {
      await tester.pumpAndSettle();
      return;
    }
    // The endless animations never settle, so let the router build and the first branch mount instead.
    await tester.pump();
    await tester.pump();
  }

  /// Tap the "+1" button of the branch [label].
  Future<void> tapPlus(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byKey(ValueKey('page-$label')), matching: find.text('plus')),
    );
    await tester.pumpAndSettle();
  }

  /// Current page of the branch container.
  double? currentPage(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page;

  testWidgets('switching a branch slides instead of jumping', (tester) async {
    await pumpShell(tester);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.physics, isA<NeverScrollableScrollPhysics>());
    expect(pageView.controller!.page, 0);

    await tester.tap(find.text('tab-c'));
    await tester.pumpAndSettle();

    expect(currentPage(tester), 2);
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

  testWidgets('a branch stops animating while it is off screen', (tester) async {
    final ticks = <String, int>{};
    await pumpShell(tester, ticks: ticks);

    // The branch on screen animates.
    final firstVisible = ticks['a'] ?? 0;
    await tester.pump(const Duration(milliseconds: 100));
    expect(ticks['a'], greaterThan(firstVisible));

    await tester.tap(find.text('tab-b'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // The branch moving into view mounts halfway through the slide; its animation must run from there on.
    final incoming = ticks['b'] ?? 0;
    await tester.pump(const Duration(milliseconds: 50));
    expect(ticks['b'], greaterThan(incoming), reason: 'the slide target must animate while it moves in');

    // Let the slide finish, then watch both branches for another stretch.
    await tester.pump(const Duration(milliseconds: 200));
    final hidden = ticks['a'] ?? 0;
    final shown = ticks['b'] ?? 0;
    await tester.pump(const Duration(milliseconds: 300));
    expect(ticks['a'], hidden, reason: 'the branch that is off screen must not keep animating');
    expect(ticks['b'], greaterThan(shown));
  });

  testWidgets('the reduced motion setting jumps instead of sliding', (tester) async {
    await pumpShell(tester, disableAnimations: true);

    await tester.tap(find.text('tab-c'));
    // A single frame is enough: the switch does not wait for a slide.
    await tester.pump();
    expect(currentPage(tester), 2);
    expect(find.text('c: 0'), findsOneWidget);

    // Animations on: the same single frame leaves the slide in flight, so the case above really covers the setting.
    await pumpShell(tester);
    await tester.tap(find.text('tab-c'));
    await tester.pump();
    expect(currentPage(tester), lessThan(2));

    await tester.pumpAndSettle();
    expect(currentPage(tester), 2);
  });
}

/// A branch page with local state, so a lost branch shows up as a reset counter.
///
/// With [ticks] it also runs an endless animation that counts its own frames there, which is how a test tells whether
/// the branch is allowed to animate.
class _CounterPage extends StatefulWidget {
  const _CounterPage({required this.label, this.ticks, super.key});

  final String label;

  /// Frame counter of the endless animation, shared by every branch; null to keep the page still.
  final Map<String, int>? ticks;

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> with SingleTickerProviderStateMixin {
  int _count = 0;

  AnimationController? _spinner;

  @override
  void initState() {
    super.initState();
    final ticks = widget.ticks;
    if (ticks == null) {
      return;
    }
    final spinner = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..addListener(() => ticks[widget.label] = (ticks[widget.label] ?? 0) + 1);
    _spinner = spinner;
    unawaited(spinner.repeat());
  }

  @override
  void dispose() {
    _spinner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text('${widget.label}: $_count'),
      FilledButton(onPressed: () => setState(() => _count++), child: const Text('plus')),
    ],
  );
}
