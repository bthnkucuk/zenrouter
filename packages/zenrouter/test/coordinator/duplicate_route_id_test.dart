import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A stack may hold the same route twice — `[/edit, /settings, /edit]` — and page
// keys have been identity-based since 3.0.0 for exactly that reason. Their
// restoration ids were not: both entries asked their navigator for the same
// bucket, and the app died on the frame that serialised it.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Shell extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(covariant TestCoordinator c) => c.inner;

  @override
  Widget build(covariant TestCoordinator c, BuildContext context) =>
      Scaffold(body: buildPath(c));
}

class Home extends AppRoute {
  @override
  Type get layout => Shell;

  @override
  Uri toUri() => Uri.parse('/home');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('home'));
}

class Products extends AppRoute {
  @override
  Type get layout => Shell;

  @override
  Uri toUri() => Uri.parse('/products');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('products'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> inner =
      NavigationPath<AppRoute>.createWith(label: 'inner', coordinator: this)
        ..bindLayout(Shell.new);

  @override
  List<StackPath> get paths => [...super.paths, inner];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Home();
}

void main() {
  testWidgets('the same route twice on one stack gets two ids', (tester) async {
    final c = TestCoordinator();
    await tester.pumpWidget(
      MaterialApp.router(restorationScopeId: 'app', routerConfig: c),
    );
    await tester.pumpAndSettle();

    unawaited(c.replace(Home()));
    await tester.pumpAndSettle();
    unawaited(c.push(Products()));
    await tester.pumpAndSettle();
    unawaited(c.push(Home()));
    await tester.pumpAndSettle();

    // Reaching this at all is the point: serialising a frame with two entries
    // claiming one bucket throws out of the scheduler.
    expect(tester.takeException(), isNull);

    final ids = c.inner.stack.map(c.resolveRouteId).toList();
    expect(ids.toSet(), hasLength(3));
    expect(
      ids,
      ['root_inner_/home', 'root_inner_/products', 'root_inner_/home#1'],
      reason:
          'only the repeat is renamed, so state saved under the first '
          'occurrence still comes back',
    );
  });

  testWidgets('a stack with no repeat is untouched', (tester) async {
    final c = TestCoordinator();
    await tester.pumpWidget(
      MaterialApp.router(restorationScopeId: 'app', routerConfig: c),
    );
    await tester.pumpAndSettle();

    unawaited(c.replace(Home()));
    await tester.pumpAndSettle();
    unawaited(c.push(Products()));
    await tester.pumpAndSettle();

    expect(c.inner.stack.map(c.resolveRouteId), [
      'root_inner_/home',
      'root_inner_/products',
    ]);
  });

  testWidgets('a route that is on no path answers plainly', (tester) async {
    // Ids are asked for on a route's behalf before it is pushed, where there is
    // no position to count from.
    final c = TestCoordinator();
    await tester.pumpWidget(
      MaterialApp.router(restorationScopeId: 'app', routerConfig: c),
    );
    await tester.pumpAndSettle();
    unawaited(c.replace(Home()));
    await tester.pumpAndSettle();

    expect(c.resolveRouteId(Home()), 'root_inner_/home');
  });
}
