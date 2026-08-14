import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// Reading `hasListeners` is exactly what this file is about, and it is
// protected on ChangeNotifier — so the check is silenced here rather than
// worked around.
// ignore_for_file: invalid_use_of_protected_member

// ============================================================================
// A listener is a bound method, so one left on a path holds the State that
// registered it, and everything under that State. Two places used to leave one
// behind: a navigator handed a different path, and a modular coordinator being
// disposed.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Leaf extends AppRoute {
  Leaf(this.id);
  final int id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/leaf/$id');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('leaf-$id'));
}

/// Its paths are deliberately kept out of [paths]: a registered path always
/// carries the coordinator's own listener, and then `hasListeners` says nothing
/// about the widget under test.
class LooseCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> first = NavigationPath.createWith(
    label: 'first',
    coordinator: this,
    stack: [Leaf(1)],
  );

  late final NavigationPath<AppRoute> second = NavigationPath.createWith(
    label: 'second',
    coordinator: this,
    stack: [Leaf(2)],
  );

  @override
  AppRoute parseRouteFromUri(Uri uri) => Leaf(0);
}

/// Renders one path and can be told to render the other.
class Host extends StatefulWidget {
  const Host({super.key, required this.coordinator});

  final LooseCoordinator coordinator;

  @override
  State<Host> createState() => HostState();
}

class HostState extends State<Host> {
  late NavigationPath<AppRoute> path = widget.coordinator.first;

  void showSecond() => setState(() => path = widget.coordinator.second);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: NavigationStack<AppRoute>(
      path: path,
      coordinator: widget.coordinator,
      resolver: (route) => StackTransition.none(
        Builder(builder: (ctx) => route.build(widget.coordinator, ctx)),
      ),
    ),
  );
}

/// A module with a path of its own and no `dispose` of its own.
class PlainModule extends RouteModule<AppRoute> {
  PlainModule(super.coordinator);

  late final NavigationPath<AppRoute> own = NavigationPath.createWith(
    label: 'module',
    coordinator: coordinator as Coordinator<AppRoute>,
  );

  @override
  List<StackPath> get paths => [own];

  @override
  FutureOr<AppRoute?> parseRouteFromUri(Uri uri) => null;
}

class ModularCoordinator extends Coordinator<AppRoute>
    with CoordinatorModular<AppRoute> {
  @override
  Set<RouteModule<AppRoute>> defineModules() => {PlainModule(this)};

  @override
  AppRoute parseRouteFromUri(Uri uri) => Leaf(0);

  @override
  AppRoute notFoundRoute(Uri uri) => Leaf(404);
}

void main() {
  testWidgets('a navigator handed another path lets go of the first', (
    tester,
  ) async {
    final c = LooseCoordinator();
    final key = GlobalKey<HostState>();
    await tester.pumpWidget(Host(key: key, coordinator: c));
    await tester.pumpAndSettle();
    expect(c.first.hasListeners, isTrue);
    expect(c.second.hasListeners, isFalse);

    key.currentState!.showSecond();
    await tester.pumpAndSettle();

    expect(
      c.first.hasListeners,
      isFalse,
      reason: 'every listener moves, not just the one that renders pages',
    );
    expect(c.second.hasListeners, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(c.first.hasListeners, isFalse);
    expect(c.second.hasListeners, isFalse);
  });

  testWidgets('disposing a modular coordinator releases its modules', (
    tester,
  ) async {
    // `paths` is composed from the module map, so clearing that map before the
    // base class walks `paths` hid the module's path from it entirely.
    final c = ModularCoordinator();
    final module = c.getModule<PlainModule>();
    expect(c.paths.map((p) => p.debugLabel), contains('module'));

    var settled = false;
    unawaited(module.own.push(Leaf(9)).then((_) => settled = true));
    await tester.pump();
    expect(settled, isFalse, reason: 'it settles on pop, and nothing popped');

    c.dispose();
    await tester.pump();

    expect(
      settled,
      isTrue,
      reason: 'the path went away, so whatever awaited it is released',
    );
    expect(module.own.hasListeners, isFalse);
  });
}
