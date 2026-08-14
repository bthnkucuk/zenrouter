import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Test Routes
// ============================================================================

class TestRoute extends RouteTarget {
  TestRoute(this.id);
  final String id;

  @override
  List<Object?> get props => [id];
}

void unawaited(Future<void> f) {}

void main() {
  group('Declarative apply is atomic', () {
    test('a surviving route keeps its pending result', () async {
      final a = TestRoute('a');
      final b = TestRoute('b');
      final path = NavigationPath<TestRoute>.create();
      // ignore: invalid_use_of_protected_member
      path.bindStack([a, b]);

      Object? bResult = 'PENDING';
      // ignore: invalid_use_of_visible_for_testing_member
      unawaited(b.onResult.future.then((v) => bResult = 'completed:$v'));

      // Append c: a and b survive untouched.
      applyDiff<TestRoute>(
        path,
        myersDiff<TestRoute>([a, b], [a, b, TestRoute('c')]),
      );
      await Future<void>.delayed(Duration.zero);

      expect(path.stack.any((r) => identical(r, b)), isTrue);
      expect(
        bResult,
        'PENDING',
        reason: 'b is still on the stack, so its result must stay pending',
      );
    });

    test('popping a survivor with a result does not throw', () async {
      final a = TestRoute('a');
      final b = TestRoute('b');
      final path = NavigationPath<TestRoute>.create();
      // ignore: invalid_use_of_protected_member
      path.bindStack([a, b]);

      applyDiff<TestRoute>(
        path,
        myersDiff<TestRoute>([a, b], [a, b, TestRoute('c')]),
      );
      await Future<void>.delayed(Duration.zero);

      // What NavigationStack's PopScope does when a page closes with a value.
      expect(() => b.completeOnResult('picked-b', null), returnsNormally);
    });

    test('one notification per declarative update', () async {
      final a = TestRoute('a');
      final b = TestRoute('b');
      final c = TestRoute('c');
      final path = NavigationPath<TestRoute>.create();
      // ignore: invalid_use_of_protected_member
      path.bindStack([a, b, c]);

      var notifications = 0;
      path.addListener(() => notifications++);

      applyDiff<TestRoute>(
        path,
        myersDiff<TestRoute>([a, b, c], [a, b, c, TestRoute('d')]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(path.stack.map((r) => r.id), ['a', 'b', 'c', 'd']);
      expect(notifications, 1);
    });

    test('the update is visible as soon as applyDiff returns', () {
      final a = TestRoute('a');
      final path = NavigationPath<TestRoute>.create();
      // ignore: invalid_use_of_protected_member
      path.bindStack([a]);

      applyDiff<TestRoute>(
        path,
        myersDiff<TestRoute>([a], [a, TestRoute('b')]),
      );

      expect(
        path.stack.map((r) => r.id),
        ['a', 'b'],
        reason: 'no async hop: the commit is synchronous',
      );
    });

    test('dropped routes are discarded and unbound', () async {
      final a = TestRoute('a');
      final b = TestRoute('b');
      final path = NavigationPath<TestRoute>.create();
      // ignore: invalid_use_of_protected_member
      path.bindStack([a, b]);

      applyDiff<TestRoute>(path, myersDiff<TestRoute>([a, b], [a]));
      await Future<void>.delayed(Duration.zero);

      expect(path.stack.map((r) => r.id), ['a']);
      expect(b.stackPath, isNull, reason: 'b left the stack');
      // ignore: invalid_use_of_visible_for_testing_member
      expect(b.onResult.isCompleted, isTrue, reason: 'b was discarded');
      expect(a.stackPath, isNotNull, reason: 'a survived');
      // ignore: invalid_use_of_visible_for_testing_member
      expect(a.onResult.isCompleted, isFalse, reason: 'a survived');
    });

    test('simultaneous delete and insert', () async {
      final a = TestRoute('a');
      final b = TestRoute('b');
      final c = TestRoute('c');
      final d = TestRoute('d');
      final path = NavigationPath<TestRoute>.create();
      // ignore: invalid_use_of_protected_member
      path.bindStack([a, b, c]);

      var notifications = 0;
      path.addListener(() => notifications++);

      applyDiff<TestRoute>(path, myersDiff<TestRoute>([a, b, c], [a, c, d]));
      await Future<void>.delayed(Duration.zero);

      expect(path.stack.map((r) => r.id), ['a', 'c', 'd']);
      expect(notifications, 1);
      expect(identical(path.stack[1], c), isTrue, reason: 'c kept its identity');
      expect(b.stackPath, isNull);
    });
  });

  group('Declarative widget state', () {
    testWidgets('appending a route preserves the existing pages', (
      tester,
    ) async {
      final lifecycle = <String>[];
      await tester.pumpWidget(_Host(lifecycle: lifecycle));
      await tester.pumpAndSettle();

      await tester.tap(find.text('inc-p1'));
      await tester.pumpAndSettle();
      expect(find.text('p1=1'), findsOneWidget);

      lifecycle.clear();
      tester.state<_HostState>(find.byType(_Host)).showPages([1, 2]);
      await tester.pumpAndSettle();

      expect(
        lifecycle,
        ['init p2'],
        reason: 'only the new page mounts; p1 must not be torn down',
      );
      expect(find.text('p1=1', skipOffstage: false), findsOneWidget);
    });
  });
}

// ============================================================================
// Widget harness
// ============================================================================

class _Host extends StatefulWidget {
  const _Host({required this.lifecycle});
  final List<String> lifecycle;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  List<int> pages = [1];

  void showPages(List<int> next) => setState(() => pages = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: NavigationStack.declarative<TestRoute>(
      routes: [for (final n in pages) TestRoute('p$n')],
      resolver: (route) => StackTransition.material(
        _Counter(label: route.id, lifecycle: widget.lifecycle),
      ),
    ),
  );
}

class _Counter extends StatefulWidget {
  const _Counter({required this.label, required this.lifecycle});
  final String label;
  final List<String> lifecycle;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int value = 0;

  @override
  void initState() {
    super.initState();
    widget.lifecycle.add('init ${widget.label}');
  }

  @override
  void dispose() {
    widget.lifecycle.add('dispose ${widget.label}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${widget.label}=$value'),
          ElevatedButton(
            onPressed: () => setState(() => value++),
            child: Text('inc-${widget.label}'),
          ),
        ],
      ),
    ),
  );
}
