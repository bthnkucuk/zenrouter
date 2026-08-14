import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Test Routes
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

/// Identity is the id; `note` is data the route carries and refreshes when it
/// is navigated to again — what [RouteTarget.onUpdate] exists for.
class Order extends AppRoute {
  Order(this.id, this.note);
  final String id;
  String note;

  int buildCount = 0;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/order/$id');

  @override
  void onUpdate(covariant Order newRoute) {
    super.onUpdate(newRoute);
    note = newRoute.note;
  }

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    buildCount++;
    return Scaffold(body: Text('NOTE=$note'));
  }
}

class Listing extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/orders');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Scaffold(body: Text('LISTING'));
}

/// Keeps scroll-like state so we can tell a refreshed page from a recreated one.
class Counter extends StatefulWidget {
  const Counter({super.key});
  @override
  State<Counter> createState() => CounterState();
}

class CounterState extends State<Counter> {
  int value = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => value++),
    child: Text('COUNT=$value'),
  );
}

/// Same as [Order] but its page also holds widget state.
class StatefulOrder extends Order {
  StatefulOrder(super.id, super.note);

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) {
    buildCount++;
    return Scaffold(
      body: Column(children: [Text('NOTE=$note'), const Counter()]),
    );
  }
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => Listing();
}

void unawaited(Future<void> f) {}

String? noteOnScreen() {
  final f = find.textContaining('NOTE=', skipOffstage: false).evaluate();
  return f.isEmpty ? null : (f.last.widget as Text).data;
}

Future<TestCoordinator> pumpApp(WidgetTester tester) async {
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  group('A route updated in place reaches the screen', () {
    testWidgets('navigate onto the route already on top', (tester) async {
      final c = await pumpApp(tester);
      final order = Order('5500', 'first');
      unawaited(c.push(order));
      await tester.pumpAndSettle();
      expect(noteOnScreen(), 'NOTE=first');

      await c.navigate(Order('5500', 'second'));
      await tester.pumpAndSettle();

      expect(order.note, 'second', reason: 'onUpdate carried the new data');
      expect(
        noteOnScreen(),
        'NOTE=second',
        reason: 'and the page must show it',
      );
      expect(c.root.stack.whereType<Order>().length, 1);
    });

    testWidgets('navigate back down onto a route deeper in the stack', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      final order = Order('5500', 'first');
      unawaited(c.push(order));
      await tester.pumpAndSettle();
      unawaited(c.push(Listing()));
      await tester.pumpAndSettle();

      await c.navigate(Order('5500', 'second'));
      await tester.pumpAndSettle();

      expect(order.note, 'second');
      expect(noteOnScreen(), 'NOTE=second');
    });

    testWidgets('pushOrMoveToTop onto the route already on top', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      final order = Order('5500', 'first');
      unawaited(c.push(order));
      await tester.pumpAndSettle();

      c.pushOrMoveToTop(Order('5500', 'second'));
      await tester.pumpAndSettle();

      expect(order.note, 'second');
      expect(noteOnScreen(), 'NOTE=second');
    });

    testWidgets('refreshing a page keeps its widget state', (tester) async {
      final c = await pumpApp(tester);
      final order = StatefulOrder('5500', 'first');
      unawaited(c.push(order));
      await tester.pumpAndSettle();

      await tester.tap(find.text('COUNT=0'));
      await tester.pumpAndSettle();
      expect(find.text('COUNT=1'), findsOneWidget);

      await c.navigate(StatefulOrder('5500', 'second'));
      await tester.pumpAndSettle();

      expect(noteOnScreen(), 'NOTE=second', reason: 'content refreshed');
      expect(
        find.text('COUNT=1'),
        findsOneWidget,
        reason: 'the page was refreshed, not recreated',
      );
    });

    testWidgets('an untouched route is not rebuilt on an unrelated push', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      final order = Order('5500', 'first');
      unawaited(c.push(order));
      await tester.pumpAndSettle();

      final before = order.buildCount;
      unawaited(c.push(Listing()));
      await tester.pumpAndSettle();
      await c.pop();
      await tester.pumpAndSettle();

      expect(
        order.buildCount,
        before,
        reason: 'a route that only sat on the stack must not be rebuilt — '
            'refreshing costs nothing when nothing changed',
      );
    });

    testWidgets('a route is rebuilt once per update, not once per commit', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      final order = Order('5500', 'first');
      unawaited(c.push(order));
      await tester.pumpAndSettle();

      final before = order.buildCount;
      await c.navigate(Order('5500', 'second'));
      await tester.pumpAndSettle();
      final afterUpdate = order.buildCount;

      // Unrelated traffic afterwards must not keep rebuilding it.
      unawaited(c.push(Listing()));
      await tester.pumpAndSettle();
      await c.pop();
      await tester.pumpAndSettle();

      expect(afterUpdate - before, 1, reason: 'the update itself rebuilds once');
      expect(order.buildCount, afterUpdate, reason: 'and then it settles');
    });
  });
}
