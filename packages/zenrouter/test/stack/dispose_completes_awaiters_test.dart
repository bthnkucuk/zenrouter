import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Test Routes
// ============================================================================

class AppRoute extends RouteTarget with RouteUnique {
  AppRoute(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/$id');

  @override
  Widget build(Coordinator coordinator, BuildContext context) =>
      Scaffold(body: Text(id));
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => AppRoute('home');
}

void unawaited(Future<void> f) {}

Future<void> pumpApp(WidgetTester tester, TestCoordinator c) async {
  await tester.pumpWidget(
    MaterialApp.router(
      routerDelegate: c.routerDelegate,
      routeInformationParser: c.routeInformationParser,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Disposing a path releases its awaiters', () {
    testWidgets('a pending push settles when the coordinator is disposed', (
      tester,
    ) async {
      final c = TestCoordinator();
      await pumpApp(tester, c);

      Object? result = 'PENDING';
      unawaited(c.push(AppRoute('picker')).then((v) => result = 'settled:$v'));
      await tester.pumpAndSettle();

      expect(result, 'PENDING', reason: 'still on screen, nothing to report');

      c.dispose();
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        result,
        'settled:null',
        reason: 'an awaiter must not outlive the path it is waiting on',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('every route left on the stack is released', (tester) async {
      final c = TestCoordinator();
      await pumpApp(tester, c);

      final a = AppRoute('a');
      final b = AppRoute('b');
      unawaited(c.push(a));
      await tester.pumpAndSettle();
      unawaited(c.push(b));
      await tester.pumpAndSettle();

      c.dispose();
      await tester.pump(const Duration(milliseconds: 20));

      for (final route in [a, b]) {
        // ignore: invalid_use_of_visible_for_testing_member
        expect(route.onResult.isCompleted, isTrue, reason: '${route.id} result');
        expect(route.stackPath, isNull, reason: '${route.id} binding');
      }

      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('disposing a bare path settles its awaiters', () async {
      final path = NavigationPath<AppRoute>.create();
      final route = AppRoute('detail');

      var settled = false;
      // ignore: invalid_use_of_visible_for_testing_member
      unawaited(route.onResult.future.then((_) => settled = true));

      unawaited(path.push(route));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(settled, isFalse);

      path.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(settled, isTrue);
      expect(route.stackPath, isNull);
    });

    test('disposing an IndexedStackPath releases its routes', () async {
      final a = AppRoute('tab-a');
      final b = AppRoute('tab-b');
      final path = IndexedStackPath<AppRoute>.create([a, b]);

      path.dispose();

      for (final route in [a, b]) {
        // ignore: invalid_use_of_visible_for_testing_member
        expect(route.onResult.isCompleted, isTrue, reason: '${route.id} result');
        expect(route.stackPath, isNull, reason: '${route.id} binding');
      }
    });

    test('dispose is safe when nothing is pending', () {
      final path = NavigationPath<AppRoute>.create();
      expect(path.dispose, returnsNormally);
    });
  });
}
