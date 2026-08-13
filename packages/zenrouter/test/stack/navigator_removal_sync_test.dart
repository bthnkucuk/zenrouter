import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Test Routes
// ============================================================================

/// A screen with a plain Flutter close button — the widget knows nothing about
/// zenrouter and pops through `Navigator`, as third-party and shared widgets do.
class AppRoute extends RouteTarget with RouteUnique {
  AppRoute(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/$id');

  @override
  Widget build(Coordinator coordinator, BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text('close-$id'),
      ),
    ),
  );
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
  group('Navigator-initiated removal sync', () {
    testWidgets('Navigator.pop() removes the route whose page was removed', (
      tester,
    ) async {
      final c = TestCoordinator();
      await pumpApp(tester, c);

      // An ordinary stack that revisits a screen: edit -> settings -> edit.
      final editA = AppRoute('edit');
      final settings = AppRoute('settings');
      final editB = AppRoute('edit');

      unawaited(c.push(editA));
      await tester.pumpAndSettle();
      unawaited(c.push(settings));
      await tester.pumpAndSettle();
      unawaited(c.push(editB));
      await tester.pumpAndSettle();

      expect(c.root.stack.length, 4);

      // The top page closes itself with plain Flutter API.
      await tester.tap(find.text('close-edit'));
      await tester.pumpAndSettle();

      expect(
        c.root.stack.length,
        3,
        reason: 'exactly one route should have left the path',
      );
      expect(
        identical(c.root.stack.last, settings),
        isTrue,
        reason: 'editB was the page removed, so settings is the new top',
      );
      expect(
        c.root.stack.any((r) => identical(r, editA)),
        isTrue,
        reason: 'editA is value-equal to editB but was not the page removed',
      );
      expect(
        c.root.stack.any((r) => identical(r, editB)),
        isFalse,
        reason: 'editB left the stack',
      );
    });

    testWidgets('bindings stay consistent with stack membership', (
      tester,
    ) async {
      final c = TestCoordinator();
      await pumpApp(tester, c);

      final editA = AppRoute('edit');
      final editB = AppRoute('edit');

      unawaited(c.push(editA));
      await tester.pumpAndSettle();
      unawaited(c.push(editB));
      await tester.pumpAndSettle();

      await tester.tap(find.text('close-edit'));
      await tester.pumpAndSettle();

      // Assert membership too: otherwise both binding expectations can hold
      // while the stack itself is corrupt (the wrong route removed, each route
      // left with the other's binding).
      expect(c.root.stack.any((r) => identical(r, editA)), isTrue);
      expect(c.root.stack.any((r) => identical(r, editB)), isFalse);
      expect(
        editA.stackPath,
        isNotNull,
        reason: 'editA is still on the stack, so it must keep its binding',
      );
      expect(
        editB.stackPath,
        isNull,
        reason: 'editB left the stack, so its binding must be cleared',
      );
    });

    testWidgets('a single Navigator.pop() still syncs the path', (
      tester,
    ) async {
      final c = TestCoordinator();
      await pumpApp(tester, c);

      unawaited(c.push(AppRoute('detail')));
      await tester.pumpAndSettle();
      expect(c.root.stack.length, 2);

      await tester.tap(find.text('close-detail'));
      await tester.pumpAndSettle();

      expect(c.root.stack.length, 1);
      expect(c.root.stack.last.id, 'home');
    });

    testWidgets('programmatic pop removes exactly one route', (tester) async {
      final c = TestCoordinator();
      await pumpApp(tester, c);

      final editA = AppRoute('edit');
      final editB = AppRoute('edit');

      unawaited(c.push(editA));
      await tester.pumpAndSettle();
      unawaited(c.push(editB));
      await tester.pumpAndSettle();
      expect(c.root.stack.length, 3);

      await c.pop();
      await tester.pumpAndSettle();

      expect(
        c.root.stack.length,
        2,
        reason: 'the declarative removal must not remove a second route',
      );
      expect(c.root.stack.any((r) => identical(r, editA)), isTrue);
      expect(c.root.stack.any((r) => identical(r, editB)), isFalse);
    });

    testWidgets('system back removes exactly one route', (tester) async {
      final c = TestCoordinator();
      await pumpApp(tester, c);

      final editA = AppRoute('edit');
      final editB = AppRoute('edit');

      unawaited(c.push(editA));
      await tester.pumpAndSettle();
      unawaited(c.push(editB));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(c.root.stack.length, 2);
      expect(c.root.stack.any((r) => identical(r, editA)), isTrue);
      expect(c.root.stack.any((r) => identical(r, editB)), isFalse);
    });
  });
}
