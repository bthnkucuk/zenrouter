import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// `pushReplacement` used to wait for the outgoing route's page to report its
// pop before pushing the replacement. A path nothing renders never gets that
// report, so the call waited for a frame that never came and the replacement
// never landed — taking the awaiting frame and the target route with it.
// ============================================================================

int discards = 0;

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Leaf extends AppRoute {
  Leaf(this.id);
  final int id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/leaf/$id');

  @override
  void onDiscard() {
    discards++;
    super.onDiscard();
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('leaf-$id'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  /// Deliberately not rendered by any `NavigationStack` — the shape of a nested
  /// layout path whose layout is off screen, or a headless coordinator.
  late final NavigationPath<AppRoute> loose = NavigationPath.createWith(
    label: 'loose',
    coordinator: this,
    stack: [Leaf(1)],
  );

  @override
  List<StackPath> get paths => [...super.paths, loose];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Leaf(0);
}

void main() {
  setUp(() => discards = 0);

  test('a replacement lands on a path nothing renders', () async {
    final c = TestCoordinator();
    unawaited(c.loose.push(Leaf(2)));
    await Future<void>.delayed(Duration.zero);

    unawaited(c.loose.pushReplacement(Leaf(3)));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(c.loose.stack.map((r) => r.toUri().path), ['/leaf/1', '/leaf/3']);
  });

  test('and the route it replaced is settled and released', () async {
    final c = TestCoordinator();
    final outgoing = Leaf(2);
    Object? received;
    var settled = false;
    unawaited(
      c.loose.push<String>(outgoing).then((value) {
        received = value;
        settled = true;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    discards = 0;

    unawaited(c.loose.pushReplacement(Leaf(3), result: 'done'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(settled, isTrue, reason: 'nothing else will complete it');
    expect(received, 'done');
    expect(discards, 1, reason: 'released once, not twice and not never');
  });

  testWidgets('rendered, it behaves as before', (tester) async {
    final c = TestCoordinator();
    await tester.pumpWidget(MaterialApp.router(routerConfig: c));
    await tester.pumpAndSettle();
    unawaited(c.push(Leaf(1)));
    await tester.pumpAndSettle();
    unawaited(c.push(Leaf(2)));
    await tester.pumpAndSettle();
    discards = 0;

    unawaited(c.pushReplacement(Leaf(3)));
    await tester.pumpAndSettle();

    expect(c.root.stack.map((r) => r.toUri().path), [
      '/leaf/0',
      '/leaf/1',
      '/leaf/3',
    ]);
    expect(discards, 1);
    expect(find.text('leaf-3'), findsOneWidget);
  });
}
