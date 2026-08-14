import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// An indexed stack builds every tab up front and keeps them all ticking. That
// is the right default — switching costs nothing — but it means a tab nobody
// opens still runs its `initState`, and an animation in a hidden tab rebuilds
// it on every frame for as long as the app runs.
//
// Two separate opt-ins on the path: `lazy` defers the building, and
// `pauseHiddenTabs` stops the ticking. They are independent — the second
// applies to a tab that has been visited, which is exactly the one `lazy` no
// longer helps with.
// ============================================================================

final List<String> builds = [];
final List<String> mounts = [];

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Tab extends AppRoute {
  Tab(this.name);
  final String name;

  @override
  List<Object?> get props => [name];

  @override
  Type get layout => TabsLayout;

  @override
  Uri toUri() => Uri.parse('/tabs/$name');

  @override
  Widget build(covariant Coordinator c, BuildContext context) {
    builds.add(name);
    return _TabBody(name: name);
  }
}

/// Reports its own mounting and animates forever, so a hidden tab that is still
/// ticking is visible in the numbers.
class _TabBody extends StatefulWidget {
  const _TabBody({required this.name});
  final String name;

  @override
  State<_TabBody> createState() => _TabBodyState();
}

class _TabBodyState extends State<_TabBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
  )..repeat();

  int frames = 0;

  @override
  void initState() {
    super.initState();
    mounts.add(widget.name);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        frames++;
        return Text('tab-${widget.name}');
      },
    ),
  );
}

class TabsLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  IndexedStackPath<AppRoute> resolvePath(covariant TabsCoordinator c) => c.tabs;
}

class TabsCoordinator extends Coordinator<AppRoute> {
  TabsCoordinator({this.lazy = false, this.pauseHiddenTabs = false});

  final bool lazy;
  final bool pauseHiddenTabs;

  late final IndexedStackPath<AppRoute> tabs = IndexedStackPath.createWith(
    coordinator: this,
    label: 'tabs',
    lazy: lazy,
    pauseHiddenTabs: pauseHiddenTabs,
    [Tab('a'), Tab('b'), Tab('c')],
  )..bindLayout(TabsLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, tabs];

  @override
  AppRoute parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['tabs', final name] => Tab(name),
    _ => Tab('a'),
  };
}

Future<TabsCoordinator> pumpApp(
  WidgetTester tester, {
  bool lazy = false,
  bool pauseHiddenTabs = false,
}) async {
  builds.clear();
  mounts.clear();
  final c = TabsCoordinator(lazy: lazy, pauseHiddenTabs: pauseHiddenTabs);
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  // Not `pumpAndSettle`: the tabs animate forever, so nothing ever settles.
  await settle(tester);
  return c;
}

/// Enough frames for a navigation to land, without waiting for animations that
/// never end.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// How many times [tab]'s body rebuilt over the next 10 frames.
int framesOf(WidgetTester tester, String tab) => tester
    .state<_TabBodyState>(
      find.ancestor(
        of: find.text('tab-$tab', skipOffstage: false),
        matching: find.byType(_TabBody, skipOffstage: false),
      ),
    )
    .frames;

Future<int> ticksOver(WidgetTester tester, String tab, int frames) async {
  final before = framesOf(tester, tab);
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return framesOf(tester, tab) - before;
}

void main() {
  group('Eagerly, which is the default', () {
    testWidgets('every tab is built at startup', (tester) async {
      await pumpApp(tester, lazy: false);

      expect(builds, ['a', 'b', 'c']);
      expect(mounts, ['a', 'b', 'c']);
    });
  });

  group('Lazily', () {
    testWidgets('only the tab on screen is built', (tester) async {
      await pumpApp(tester, lazy: true);

      expect(builds, ['a']);
      expect(mounts, ['a'], reason: 'no unopened tab has run its initState');
      expect(find.text('tab-a'), findsOneWidget);
    });

    testWidgets('a tab is built when it is first shown', (tester) async {
      final c = await pumpApp(tester, lazy: true);

      await c.tabs.goToIndexed(2);
      await settle(tester);

      expect(builds, ['a', 'c']);
      expect(find.text('tab-c'), findsOneWidget);
      expect(find.text('tab-b', skipOffstage: false), findsNothing);
    });

    testWidgets('and kept from then on', (tester) async {
      final c = await pumpApp(tester, lazy: true);

      await c.tabs.goToIndexed(1);
      await settle(tester);
      final mountedOnce = List<String>.of(mounts);
      await c.tabs.goToIndexed(0);
      await settle(tester);
      await c.tabs.goToIndexed(1);
      await settle(tester);

      expect(mounts, mountedOnce, reason: 'a visited tab is not rebuilt');
      expect(builds, ['a', 'b']);
    });

    testWidgets('landing on a later tab builds only that one', (tester) async {
      // A deep link straight into the third tab must not drag the first two in.
      builds.clear();
      mounts.clear();
      final c = TabsCoordinator(lazy: true);
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await settle(tester);
      await c.navigate(Tab('c'));
      await settle(tester);

      expect(builds, ['a', 'c']);
      expect(find.text('tab-c'), findsOneWidget);
    });
  });

  group('Hidden tabs keep ticking, unless told not to', () {
    testWidgets('by default they do', (tester) async {
      await pumpApp(tester);

      expect(
        await ticksOver(tester, 'c', 10),
        greaterThan(5),
        reason: 'Flutter keeps every child of an IndexedStack ticking',
      );
    });

    testWidgets('with pauseHiddenTabs the one off screen stops', (
      tester,
    ) async {
      final c = await pumpApp(tester, pauseHiddenTabs: true);
      await c.tabs.goToIndexed(1);
      await settle(tester);

      expect(await ticksOver(tester, 'a', 10), 0, reason: 'off screen now');
      expect(
        await ticksOver(tester, 'b', 10),
        greaterThan(5),
        reason: 'the visible tab animates as always',
      );
    });

    testWidgets('it picks up again on return', (tester) async {
      final c = await pumpApp(tester, pauseHiddenTabs: true);
      await c.tabs.goToIndexed(1);
      await settle(tester);
      await c.tabs.goToIndexed(0);
      await settle(tester);

      expect(await ticksOver(tester, 'a', 10), greaterThan(5));
    });

    testWidgets('an animation in flight freezes and resumes', (tester) async {
      // The cost of the flag, and the reason it is not the default: an
      // animation does not finish off screen, it waits.
      final c = await pumpApp(tester, pauseHiddenTabs: true);
      final a = tester.state<_TabBodyState>(
        find.ancestor(
          of: find.text('tab-a', skipOffstage: false),
          matching: find.byType(_TabBody, skipOffstage: false),
        ),
      );
      a.controller.stop();
      a.controller.value = 0;
      unawaited(a.controller.forward());
      // The first frame after starting only sets the baseline; the second is
      // the one that advances it.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 30));
      expect(a.controller.value, greaterThan(0), reason: 'it is under way');

      await c.tabs.goToIndexed(1);
      await settle(tester);
      final hiddenAt = a.controller.value;
      await tester.pump(const Duration(seconds: 1));

      expect(a.controller.value, hiddenAt, reason: 'frozen where it was');
      expect(
        a.controller.isCompleted,
        isFalse,
        reason: 'a second is ten times its duration, and it still has not run',
      );

      await c.tabs.goToIndexed(0);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(a.controller.isCompleted, isTrue, reason: 'finished on return');
    });

    testWidgets('and it is independent of lazy', (tester) async {
      // Lazy alone leaves a visited tab ticking — which is the case it cannot
      // help with, and the reason the two are separate flags.
      final c = await pumpApp(tester, lazy: true);
      await c.tabs.goToIndexed(1);
      await settle(tester);
      await c.tabs.goToIndexed(0);
      await settle(tester);

      expect(
        await ticksOver(tester, 'b', 10),
        greaterThan(5),
        reason: 'built, hidden, and still ticking',
      );
    });
  });
}
