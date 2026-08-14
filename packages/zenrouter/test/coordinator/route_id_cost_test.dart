import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A route's restoration id spells out the paths it sits under. Working that out
// used to read the coordinator's active layout chain once per link — and each
// read walks the whole hierarchy — then do the entire walk a second time for
// the caller that tolerates an unlabelled path. The renderer asks through that
// second one, once per tab, every time the tab children are rebuilt.
// ============================================================================

/// Every resolution of a layout's path, which is what both the chain walk and
/// the label lookup are made of.
int pathResolves = 0;

abstract class AppRoute extends RouteTarget with RouteUnique {}

/// A layout nested under [parent], so a chain of any depth can be built.
abstract class Shell extends AppRoute with RouteLayout<AppRoute> {
  Shell(this.level);
  final int level;

  @override
  List<Object?> get props => [level];

  @override
  NavigationPath<AppRoute> resolvePath(covariant TestCoordinator c) {
    pathResolves++;
    return c.shellPath(level);
  }

  @override
  Uri toUri() => Uri.parse('/shell$level');

  @override
  Widget build(covariant TestCoordinator c, BuildContext context) =>
      Scaffold(body: buildPath(c));
}

class Shell1 extends Shell {
  Shell1() : super(1);
}

class Shell2 extends Shell {
  Shell2() : super(2);
  @override
  Type get layout => Shell1;
}

class Shell3 extends Shell {
  Shell3() : super(3);
  @override
  Type get layout => Shell2;
}

class Leaf extends AppRoute {
  Leaf(this.depth);
  final int depth;

  @override
  List<Object?> get props => [depth];

  @override
  Type get layout => switch (depth) {
    1 => Shell1,
    2 => Shell2,
    _ => Shell3,
  };

  @override
  Uri toUri() => Uri.parse('/leaf$depth');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('leaf$depth'));
}

/// Sits on the root path — the case that has no chain to walk at all.
class Flat extends AppRoute {
  @override
  List<Object?> get props => const [];

  @override
  Uri toUri() => Uri.parse('/flat');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('flat'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  TestCoordinator() {
    p1.bindLayout(Shell1.new);
    p2.bindLayout(Shell2.new);
    p3.bindLayout(Shell3.new);
  }

  late final p1 = NavigationPath<AppRoute>.createWith(
    coordinator: this,
    label: 's1',
  );
  late final p2 = NavigationPath<AppRoute>.createWith(
    coordinator: this,
    label: 's2',
  );
  late final p3 = NavigationPath<AppRoute>.createWith(
    coordinator: this,
    label: 's3',
  );

  NavigationPath<AppRoute> shellPath(int level) => switch (level) {
    1 => p1,
    2 => p2,
    _ => p3,
  };

  @override
  List<StackPath> get paths => [...super.paths, p1, p2, p3];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Leaf(1);
}

/// Path resolutions spent on one id, for a route nested [depth] layouts deep.
Future<({int plain, int nullable})> costAt(
  WidgetTester tester,
  int depth,
) async {
  final c = TestCoordinator();
  await tester.pumpWidget(
    MaterialApp.router(restorationScopeId: 'app', routerConfig: c),
  );
  await tester.pumpAndSettle();
  await c.navigate(Leaf(depth));
  await tester.pumpAndSettle();

  final route = Leaf(depth);
  pathResolves = 0;
  c.resolveRouteId(route);
  final plain = pathResolves;

  pathResolves = 0;
  c.tryResolveRouteId(route);
  return (plain: plain, nullable: pathResolves);
}

void main() {
  testWidgets('asking for an id the forgiving way costs no more', (
    tester,
  ) async {
    for (final depth in [1, 2, 3]) {
      final cost = await costAt(tester, depth);
      expect(
        cost.nullable,
        cost.plain,
        reason:
            'at depth $depth it used to be double: the label check walked the '
            'chain, then the id built it walked it again',
      );
    }
  });

  testWidgets('and nesting costs a fixed amount per layout', (tester) async {
    final one = (await costAt(tester, 1)).plain;
    final two = (await costAt(tester, 2)).plain;
    final three = (await costAt(tester, 3)).plain;

    expect(
      one,
      greaterThan(0),
      reason:
          'the id spells out the layout labels, so resolving one has to reach '
          'the paths — without this the equality below holds at 0 == 0 and '
          'proves nothing',
    );
    expect(
      three - two,
      two - one,
      reason:
          'each link used to re-read the active layout chain, and reading it '
          'walks every layout — so the cost grew with the square of the depth '
          '(measured 3, 8, 15)',
    );
  });

  testWidgets('a route with no layout does not read the chain at all', (
    tester,
  ) async {
    // The chain is read once for the whole walk, which is only a saving if the
    // routes with nothing to walk are not made to pay for it. The outermost
    // shell of every app is one of them, and it resolves an id on every rebuild.
    final c = TestCoordinator();
    await tester.pumpWidget(
      MaterialApp.router(restorationScopeId: 'app', routerConfig: c),
    );
    await tester.pumpAndSettle();
    await c.navigate(Leaf(3));
    await tester.pumpAndSettle();

    pathResolves = 0;
    c.resolveRouteId(Flat());

    expect(pathResolves, 0);
  });

  testWidgets('the id itself is unchanged', (tester) async {
    // Nothing else pins the string, and it is what a relaunch reads back: an
    // id that shifts silently loses the state it was saved under.
    final c = TestCoordinator();
    await tester.pumpWidget(
      MaterialApp.router(restorationScopeId: 'app', routerConfig: c),
    );
    await tester.pumpAndSettle();
    await c.navigate(Leaf(3));
    await tester.pumpAndSettle();

    expect(c.resolveRouteId(Leaf(3)), 'root_s3_s2_s1_/leaf3');
    expect(c.resolveRouteId(Flat()), 'root__/flat');
  });
}
