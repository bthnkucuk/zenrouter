import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// `onDiscard` is where an app releases what a route owns — a subscription, a
// controller, a listener registered on its behalf. A route dropped without it
// keeps whatever registered it alive for good, so the leak is the app's state,
// not the route.
//
// Popping already ran it. Clearing a path did not, and clearing is how
// `replace`, a layout leaving the stack, and a `DeeplinkStrategy.stack` arrival
// all remove routes.
// ============================================================================

/// Stands in for something the app owns and the route subscribes to.
final store = ChangeNotifier();
int discards = 0;

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Leaf extends AppRoute {
  Leaf(this.id) {
    store.addListener(_onChanged);
  }

  final int id;

  void _onChanged() {}

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/leaf/$id');

  @override
  void onDiscard() {
    discards++;
    store.removeListener(_onChanged);
    super.onDiscard();
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('leaf-$id'));
}

class Shell extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(covariant TestCoordinator c) => c.inner;

  @override
  Widget build(covariant TestCoordinator c, BuildContext context) =>
      Scaffold(body: buildPath(c));
}

/// Lives inside [Shell], so it leaves when the shell does.
class Inner extends AppRoute {
  Inner(this.id) {
    store.addListener(_onChanged);
  }

  final int id;

  void _onChanged() {}

  @override
  List<Object?> get props => [id];

  @override
  Type get layout => Shell;

  @override
  Uri toUri() => Uri.parse('/inner/$id');

  @override
  void onDiscard() {
    discards++;
    store.removeListener(_onChanged);
    super.onDiscard();
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('inner-$id'));
}

class Home extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('home'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> inner = NavigationPath.createWith(
    label: 'inner',
    coordinator: this,
  )..bindLayout(Shell.new);

  @override
  List<StackPath> get paths => [...super.paths, inner];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Home();
}

Future<TestCoordinator> pumpApp(WidgetTester tester) async {
  discards = 0;
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  group('A route removed by clearing a path is discarded', () {
    testWidgets('by replace', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Leaf(1)));
      await tester.pumpAndSettle();

      unawaited(c.replace(Leaf(2)));
      await tester.pumpAndSettle();

      expect(discards, 1, reason: 'leaf 1 left, leaf 2 is on screen');
    });

    testWidgets('by a layout leaving the stack', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Inner(1)));
      await tester.pumpAndSettle();
      discards = 0;

      await c.pop();
      await tester.pumpAndSettle();

      expect(discards, greaterThanOrEqualTo(1));
    });

    testWidgets('by a deep link that names a stack', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Leaf(1)));
      await tester.pumpAndSettle();

      await c.recoverStack([Leaf(2)]);
      await tester.pumpAndSettle();

      expect(discards, 1);
    });

    testWidgets('by the path being disposed', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Leaf(1)));
      await tester.pumpAndSettle();

      c.dispose();

      expect(discards, 1);
    });

    testWidgets('and popping still discards exactly once', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Leaf(1)));
      await tester.pumpAndSettle();

      await c.pop();
      await tester.pumpAndSettle();

      expect(discards, 1);
    });
  });

  testWidgets('a route put straight back is not discarded', (tester) async {
    // Resolving a layout activates the instance already on the path. Discarding
    // it there would release a route that never left.
    final c = await pumpApp(tester);
    final live = Leaf(1);
    unawaited(c.root.push(live));
    await tester.pumpAndSettle();
    discards = 0;

    await c.root.activateRoute(live);
    await tester.pumpAndSettle();

    expect(discards, 0);
    expect(c.root.stack, [live]);
    expect(live.isDiscarded, isFalse);
  });
}
