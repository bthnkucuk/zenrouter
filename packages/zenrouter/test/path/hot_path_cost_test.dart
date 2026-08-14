import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Two things sat on every notification and paid for work nobody asked for:
// reading a path's stack copied it, and saving restoration state re-serialised
// every route on every stack whether or not the navigation had moved.
// ============================================================================

/// Counts what the restoration path is actually made of: one `Uri` per route
/// per serialisation.
int uriBuilds = 0;

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Leaf extends AppRoute {
  Leaf(this.id);
  final int id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() {
    uriBuilds++;
    return Uri.parse('/leaf/$id');
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('leaf-$id'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => Leaf(0);
}

Future<TestCoordinator> pumpDeep(WidgetTester tester, int depth) async {
  final c = TestCoordinator();
  await tester.pumpWidget(
    MaterialApp.router(restorationScopeId: 'app', routerConfig: c),
  );
  await tester.pumpAndSettle();
  for (var i = 1; i <= depth; i++) {
    unawaited(c.push(Leaf(i)));
    await tester.pumpAndSettle();
  }
  uriBuilds = 0;
  return c;
}

void main() {
  group('A notification that changes nothing costs nothing', () {
    testWidgets('the stacks are not re-serialised', (tester) async {
      final c = await pumpDeep(tester, 20);

      c.markNeedRebuild();
      await tester.pumpAndSettle();

      expect(
        uriBuilds,
        lessThan(3),
        reason:
            'it used to build one Uri per route on every stack, so this '
            'grew with the depth of the navigation',
      );
    });

    testWidgets('and the cost does not grow with the stack', (tester) async {
      final shallow = await pumpDeep(tester, 2);
      shallow.markNeedRebuild();
      await tester.pumpAndSettle();
      final atTwo = uriBuilds;

      final deep = await pumpDeep(tester, 20);
      deep.markNeedRebuild();
      await tester.pumpAndSettle();

      expect(uriBuilds, atTwo);
    });
  });

  group('Reading a stack does not copy it', () {
    testWidgets('the same view is handed out every time', (tester) async {
      // It is a view, so it must be identical across reads *and* keep up with
      // the path. Copying per read put an allocation on `activeRoute`,
      // `currentUri` and every renderer, several times per navigation.
      final c = await pumpDeep(tester, 3);

      final first = c.root.stack;
      expect(identical(c.root.stack, first), isTrue);
      expect(first.length, 4);

      unawaited(c.push(Leaf(99)));
      await tester.pumpAndSettle();

      expect(first.length, 5, reason: 'the view keeps up with the path');
      expect(c.root.stack.last.toUri().path, '/leaf/99');
    });

    testWidgets('and it cannot be written through', (tester) async {
      final c = await pumpDeep(tester, 1);

      expect(() => (c.root.stack as List).clear(), throwsUnsupportedError);
    });
  });

  testWidgets('a navigation that does change the stacks still saves', (
    tester,
  ) async {
    // The skip above must not swallow a real change: the restorable is what a
    // relaunch reads back.
    final c = await pumpDeep(tester, 2);

    unawaited(c.push(Leaf(50)));
    await tester.pumpAndSettle();

    expect(uriBuilds, greaterThan(0));
  });
}
