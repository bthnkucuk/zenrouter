import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A `NavigatorObserver` may only be attached to one `Navigator`
// (`NavigatorState.initState` asserts `observer.navigator == null`). A
// coordinator runs several navigators at once — that is what layouts are — so
// observers have to be built per navigator rather than shared.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Spy extends NavigatorObserver {
  Spy() {
    created++;
  }

  static int created = 0;

  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

// ---------------------------------------------------------------------------
// Shape A: a nested NavigationPath layout — two concurrent navigators.
// ---------------------------------------------------------------------------

class ShellA extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(covariant CoordA c) => c.nested;

  @override
  Uri toUri() => Uri.parse('/shellA');

  @override
  Widget build(covariant CoordA c, BuildContext context) =>
      Scaffold(body: buildPath(c));
}

class InnerA extends AppRoute {
  @override
  Type get layout => ShellA;

  @override
  Uri toUri() => Uri.parse('/shellA/inner');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('innerA'));
}

class Plain extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/plain');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('plain'));
}

class CoordA extends Coordinator<AppRoute> with CoordinatorNavigatorObserver {
  final spies = <Spy>[];

  late final NavigationPath<AppRoute> nested = NavigationPath.createWith(
    label: 'nested',
    coordinator: this,
  )..bindLayout(ShellA.new);

  List<NavigatorObserver> _build() {
    final spy = Spy();
    spies.add(spy);
    return [spy];
  }

  @override
  NavigatorObserverListGetter get observersBuilder => _build;

  @override
  List<StackPath> get paths => [...super.paths, nested];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Plain();
}

// ---------------------------------------------------------------------------
// Shape B: a tab shell with a nested stack inside one tab.
// ---------------------------------------------------------------------------

class TabShell extends AppRoute with RouteLayout<AppRoute> {
  @override
  IndexedStackPath<AppRoute> resolvePath(covariant CoordB c) => c.tabs;

  @override
  Uri toUri() => Uri.parse('/tabs');

  @override
  Widget build(covariant CoordB c, BuildContext context) =>
      Scaffold(body: buildPath(c));
}

class TabOneLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  Type get layout => TabShell;

  @override
  NavigationPath<AppRoute> resolvePath(covariant CoordB c) => c.tabOne;

  @override
  Uri toUri() => Uri.parse('/tabs/one');
}

class TabTwo extends AppRoute {
  @override
  Type get layout => TabShell;

  @override
  Uri toUri() => Uri.parse('/tabs/two');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('tab2'));
}

class TabInner extends AppRoute {
  @override
  Type get layout => TabOneLayout;

  @override
  Uri toUri() => Uri.parse('/tabs/one/inner');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('tabInner'));
}

class CoordB extends Coordinator<AppRoute> with CoordinatorNavigatorObserver {
  late final IndexedStackPath<AppRoute> tabs =
      IndexedStackPath.createWith(coordinator: this, label: 'tabs', [
        TabOneLayout(),
        TabTwo(),
      ])..bindLayout(TabShell.new);

  late final NavigationPath<AppRoute> tabOne = NavigationPath.createWith(
    label: 'tabOne',
    coordinator: this,
  )..bindLayout(TabOneLayout.new);

  @override
  NavigatorObserverListGetter get observersBuilder => () => [Spy()];

  @override
  List<StackPath> get paths => [...super.paths, tabs, tabOne];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Plain();
}

void unawaited(Future<void> f) {}

void main() {
  setUp(() => Spy.created = 0);

  group('Observers are built per navigator', () {
    testWidgets('a nested layout does not reuse one observer instance', (
      tester,
    ) async {
      final c = CoordA();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'boot is fine either way');

      unawaited(c.push(InnerA()));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'a second concurrent navigator must get its own observers, not '
            'the instance the first one already claimed',
      );
      expect(
        c.spies.length,
        greaterThanOrEqualTo(2),
        reason: 'one build per navigator',
      );
      expect(
        c.spies.map((s) => s.navigator).toSet().length,
        c.spies.length,
        reason: 'each observer is attached to a distinct navigator',
      );
    });

    testWidgets('a tab shell with a nested stack behaves the same', (
      tester,
    ) async {
      final c = CoordB();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      unawaited(c.push(TabInner()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('Observers keep their state', () {
    testWidgets('the builder runs once per navigator, not once per build', (
      tester,
    ) async {
      final c = CoordA();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      final afterBoot = Spy.created;
      unawaited(c.push(Plain()));
      await tester.pumpAndSettle();
      unawaited(c.push(Plain()));
      await tester.pumpAndSettle();

      expect(
        Spy.created,
        afterBoot,
        reason: 'ordinary navigation must not rebuild observers; rebuilding '
            'them is what loses analytics counters and RouteObserver '
            'subscriptions',
      );
    });

    testWidgets('an observer accumulates across pushes', (tester) async {
      final c = CoordA();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      unawaited(c.push(Plain()));
      await tester.pumpAndSettle();
      unawaited(c.push(Plain()));
      await tester.pumpAndSettle();

      final total = c.spies.fold<int>(0, (sum, s) => sum + s.pushes);
      expect(
        total,
        greaterThanOrEqualTo(2),
        reason: 'events must reach observers that survive between navigations',
      );
    });
  });
}
