import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Test Routes
// ============================================================================

class TestRoute extends RouteTarget with RouteUnique {
  TestRoute(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/$id');

  @override
  Widget build(Coordinator coordinator, BuildContext context) =>
      const Placeholder();
}

/// A route whose pop needs async confirmation, e.g. "discard unsaved changes?".
/// [gate] stands in for the dialog the user has to answer.
class AsyncGuardedRoute extends TestRoute with RouteGuard {
  AsyncGuardedRoute(super.id, this.gate);
  final Completer<bool> gate;

  @override
  FutureOr<bool> popGuard() => gate.future;
}

/// A route that refuses every pop, and counts how often it was asked.
class NeverPopRoute extends TestRoute with RouteGuard {
  NeverPopRoute(super.id);

  int guardCalls = 0;

  @override
  FutureOr<bool> popGuard() {
    guardCalls++;
    return false;
  }
}

/// A route gated by an async check before it can be pushed, e.g. a session
/// validation that runs inside the redirect pipeline.
class SlowRedirectRoute extends TestRoute with RouteRedirect<TestRoute> {
  SlowRedirectRoute(super.id, this.delay);
  final Duration delay;

  @override
  FutureOr<TestRoute> redirect() async {
    await Future<void>.delayed(delay);
    return this;
  }
}

void main() {
  group('Mutation serialization', () {
    test('a push during an async pop guard cannot steal the pop', () async {
      final gate = Completer<bool>();
      final guarded = AsyncGuardedRoute('B', gate);
      final path = NavigationPath<TestRoute>.create(
        label: 'p',
        stack: [TestRoute('A')],
      );

      unawaited(path.push(guarded));
      await Future<void>.delayed(Duration.zero);
      expect(path.stack.map((r) => r.id), ['A', 'B']);

      // The user taps back on B; its guard opens a dialog and awaits.
      final popFuture = path.pop();
      await Future<void>.delayed(Duration.zero);

      // While the dialog is open, a deep link pushes C.
      final intruder = NeverPopRoute('C');
      unawaited(path.push(intruder));
      await Future<void>.delayed(Duration.zero);

      // The user confirms: yes, discard B.
      gate.complete(true);
      expect(await popFuture, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // B — the route the guard was actually asked about — is the one removed.
      expect(
        path.stack.map((r) => r.id),
        ['A', 'C'],
        reason: 'pop must remove the guarded route, not whatever raced to the top',
      );
      expect(
        intruder.guardCalls,
        0,
        reason: 'C was never popped, so its guard should not have been consulted',
      );
      expect(
        intruder.stackPath,
        isNotNull,
        reason: 'C stayed on the stack, so it must keep its path binding',
      );
    });

    test('pushes land in call order despite a slow redirect', () async {
      final path = NavigationPath<TestRoute>.create(
        label: 'p',
        stack: [TestRoute('Home')],
      );

      // Profile runs a 30ms auth check; Settings runs none.
      unawaited(path.push(SlowRedirectRoute('Profile', Duration(milliseconds: 30))));
      unawaited(path.push(TestRoute('Settings')));

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        path.stack.map((r) => r.id),
        ['Home', 'Profile', 'Settings'],
        reason: 'the last route asked for must end up on top',
      );
    });

    test('a queued push is not blocked until the previous route pops', () async {
      final path = NavigationPath<TestRoute>.create(label: 'p');

      // push() completes on pop, so its future stays pending here. The queue
      // must only hold the mutating region, otherwise the second push would
      // never land.
      unawaited(path.push(TestRoute('A')));
      unawaited(path.push(TestRoute('B')));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(path.stack.map((r) => r.id), ['A', 'B']);
    });

    test('a blocked guard leaves the stack untouched for the next mutation',
        () async {
      final blocker = NeverPopRoute('B');
      final path = NavigationPath<TestRoute>.create(
        label: 'p',
        stack: [TestRoute('A')],
      );

      unawaited(path.push(blocker));
      await Future<void>.delayed(Duration.zero);

      expect(await path.pop(), isFalse);
      expect(blocker.guardCalls, 1);

      unawaited(path.push(TestRoute('C')));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(path.stack.map((r) => r.id), ['A', 'B', 'C']);
    });

    test('interleaved pops apply one at a time', () async {
      final path = NavigationPath<TestRoute>.create(
        label: 'p',
        stack: [TestRoute('A'), TestRoute('B'), TestRoute('C')],
      );

      final results = await Future.wait([path.pop(), path.pop()]);

      expect(results, [true, true]);
      expect(path.stack.map((r) => r.id), ['A']);
    });
  });
}
