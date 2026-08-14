import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Restoring a path replaces its whole stack, and the routes that were on it
// before are leaving. They used to be dropped in silence — no `onDiscard`, and
// still pointing at a path they were no longer on.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Leaf extends AppRoute {
  Leaf(this.id);
  final int id;
  int discards = 0;

  @override
  List<Object?> get props => [id];

  @override
  void onDiscard() {
    discards++;
    super.onDiscard();
  }

  @override
  Uri toUri() => Uri.parse('/leaf/$id');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('leaf-$id'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => Leaf(0);
}

void main() {
  testWidgets('a route the restored stack leaves out is released', (
    tester,
  ) async {
    final c = TestCoordinator();
    await tester.pumpWidget(MaterialApp.router(routerConfig: c));
    await tester.pumpAndSettle();

    final launched = Leaf(1);
    unawaited(c.push(launched));
    await tester.pumpAndSettle();

    var settled = false;
    unawaited(c.push(Leaf(2)).then((_) => settled = true));
    await tester.pumpAndSettle();
    final dropped = c.root.stack.last as Leaf;

    // What a real restore hands back: routes rebuilt from the saved data, not
    // the instances that happen to be on the path.
    c.root.restore(<RouteTarget>[Leaf(1), Leaf(9)]);
    await tester.pumpAndSettle();

    expect(dropped.discards, 1);
    expect(dropped.stackPath, isNull);
    expect(
      settled,
      isTrue,
      reason: 'whatever awaited the route it replaced is released with it',
    );
    expect(launched.discards, 1);
    expect(c.root.stack.map((r) => r.toUri().path), ['/leaf/1', '/leaf/9']);
  });

  testWidgets('and one it keeps by identity is not', (tester) async {
    final c = TestCoordinator();
    await tester.pumpWidget(MaterialApp.router(routerConfig: c));
    await tester.pumpAndSettle();

    final kept = Leaf(1);
    unawaited(c.push(kept));
    await tester.pumpAndSettle();

    // Restoring from the in-memory default hands back the live instances.
    c.root.restore(<RouteTarget>[...c.root.stack]);
    await tester.pumpAndSettle();

    expect(kept.discards, 0);
    expect(kept.stackPath, same(c.root));
  });
}
