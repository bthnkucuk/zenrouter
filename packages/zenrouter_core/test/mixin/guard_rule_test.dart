// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

class TestRoute extends RouteTarget {
  TestRoute(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  String toString() => 'TestRoute($id)';
}

class RuleGuardedRoute extends TestRoute with RouteGuardRule<TestRoute> {
  RuleGuardedRoute(super.id, {required this.rules});

  final List<GuardRule> rules;

  @override
  List<GuardRule> get guardRules => rules;
}

void main() {
  group('GuardRule defaults', () {
    const rule = _DefaultGuardRule();
    final route = TestRoute('1');
    final coordinator = _UnusedCoordinator();

    test('canPopRule defaults to true', () {
      expect(rule.canPopRule(route), isTrue);
    });

    test('canPopListenableRule defaults to null', () {
      expect(rule.canPopListenableRule(route), isNull);
    });

    test('guardRule defaults to null', () async {
      expect(await rule.guardRule(route), isNull);
    });

    test('canPopRuleWith defaults to canPopRule', () {
      expect(rule.canPopRuleWith(coordinator, route), isTrue);
    });

    test('canPopListenableRuleWith defaults to canPopListenableRule', () {
      expect(rule.canPopListenableRuleWith(coordinator, route), isNull);
    });

    test('guardRuleWith defaults to guardRule', () async {
      expect(await rule.guardRuleWith(coordinator, route), isNull);
    });

    test('const constructor is usable', () {
      expect(const _DefaultGuardRule(), isA<GuardRule<TestRoute>>());
    });
  });

  group('GuardRule With overrides', () {
    test('canPopRuleWith can differ from canPopRule', () {
      final route = TestRoute('1');
      const rule = _CoordinatorCanPopRule();

      expect(rule.canPopRule(route), isTrue);
      expect(rule.canPopRuleWith(_UnusedCoordinator(), route), isFalse);
    });

    test('canPopListenableRuleWith can differ from canPopListenableRule', () {
      final route = TestRoute('1');
      final withOnly = _TestListenable();
      final rule = _CoordinatorListenableRule(withOnly);

      expect(rule.canPopListenableRule(route), isNull);
      expect(
        rule.canPopListenableRuleWith(_UnusedCoordinator(), route),
        same(withOnly),
      );
    });

    test('guardRuleWith can override without changing guardRule', () async {
      final route = TestRoute('1');
      const rule = _CoordinatorOnlyAllowRule();

      expect(await rule.guardRule(route), isNull);
      expect(await rule.guardRuleWith(_UnusedCoordinator(), route), isTrue);
    });

    test('guardRuleWith defaults through to overridden guardRule', () async {
      final route = TestRoute('1');
      const rule = _NonCoordinatorBlockRule();

      expect(await rule.guardRule(route), isFalse);
      expect(await rule.guardRuleWith(_UnusedCoordinator(), route), isFalse);
    });
  });

  group('RouteGuardRule.canPop / canPopWith', () {
    test('implements RouteGuard', () {
      expect(RuleGuardedRoute('1', rules: []), isA<RouteGuard>());
    });

    test('canPop is true for empty rules', () {
      expect(RuleGuardedRoute('1', rules: []).canPop, isTrue);
    });

    test('canPop is true when every rule allows', () {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _FixedCanPopRule(true), const _FixedCanPopRule(true)],
      );
      expect(route.canPop, isTrue);
    });

    test('canPop is false when any rule requires intercept', () {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _FixedCanPopRule(true), const _FixedCanPopRule(false)],
      );
      expect(route.canPop, isFalse);
    });

    test('canPopWith uses canPopRuleWith', () {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _CoordinatorCanPopRule()],
      );
      expect(route.canPop, isTrue);
      expect(route.canPopWith(_UnusedCoordinator()), isFalse);
    });
  });

  group('RouteGuardRule.canPopListenable / canPopListenableWith', () {
    test('null when no rules expose a listenable', () {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _FixedCanPopRule(true)],
      );
      expect(route.canPopListenable, isNull);
      expect(route.canPopListenableWith(_UnusedCoordinator()), isNull);
    });

    test('returns single listenable unchanged', () {
      final notifier = _TestListenable();
      final route = RuleGuardedRoute('1', rules: [_ListenableRule(notifier)]);
      expect(route.canPopListenable, same(notifier));
    });

    test('skips rules that return null listenable', () {
      final notifier = _TestListenable();
      final route = RuleGuardedRoute(
        '1',
        rules: [
          const _FixedCanPopRule(true),
          _ListenableRule(notifier),
          const _FixedCanPopRule(true),
        ],
      );
      expect(route.canPopListenable, same(notifier));
    });

    test('merges multiple listenables', () {
      final a = _TestListenable();
      final b = _TestListenable();
      final route = RuleGuardedRoute(
        '1',
        rules: [_ListenableRule(a), _ListenableRule(b)],
      );
      final merged = route.canPopListenable!;
      expect(merged, isNot(same(a)));
      expect(merged, isNot(same(b)));

      var notified = 0;
      merged.addListener(() => notified++);
      a.notify();
      b.notify();
      expect(notified, 2);
    });

    test('merged listenable removeListener stops notifications', () {
      final a = _TestListenable();
      final b = _TestListenable();
      final route = RuleGuardedRoute(
        '1',
        rules: [_ListenableRule(a), _ListenableRule(b)],
      );
      final merged = route.canPopListenable!;

      var notified = 0;
      void listener() => notified++;
      merged.addListener(listener);
      a.notify();
      expect(notified, 1);

      merged.removeListener(listener);
      a.notify();
      b.notify();
      expect(notified, 1);
    });

    test('canPopListenableWith uses canPopListenableRuleWith', () {
      final withOnly = _TestListenable();
      final route = RuleGuardedRoute(
        '1',
        rules: [_CoordinatorListenableRule(withOnly)],
      );
      expect(route.canPopListenable, isNull);
      expect(route.canPopListenableWith(_UnusedCoordinator()), same(withOnly));
    });

    test('canPopListenableWith merges multiple With listenables', () {
      final a = _TestListenable();
      final b = _TestListenable();
      final route = RuleGuardedRoute(
        '1',
        rules: [_CoordinatorListenableRule(a), _CoordinatorListenableRule(b)],
      );
      final merged = route.canPopListenableWith(_UnusedCoordinator())!;
      expect(merged, isNot(same(a)));
      expect(merged, isNot(same(b)));

      var notified = 0;
      merged.addListener(() => notified++);
      a.notify();
      b.notify();
      expect(notified, 2);
    });
  });

  group('RouteGuardRule.popGuard chain', () {
    test('empty rules allow pop', () async {
      expect(await RuleGuardedRoute('1', rules: []).popGuard(), isTrue);
    });

    test('all-null rules allow pop', () async {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _ContinueRule(), const _ContinueRule()],
      );
      expect(await route.popGuard(), isTrue);
    });

    test('false blocks pop', () async {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _NonCoordinatorBlockRule()],
      );
      expect(await route.popGuard(), isFalse);
    });

    test('true allows pop', () async {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _NonCoordinatorAllowRule()],
      );
      expect(await route.popGuard(), isTrue);
    });

    test('null continues to next rule which can block', () async {
      final second = _CountingRule(false);
      final route = RuleGuardedRoute(
        '1',
        rules: [const _ContinueRule(), second],
      );
      expect(await route.popGuard(), isFalse);
      expect(second.callCount, 1);
    });

    test('true short-circuits later rules', () async {
      final later = _CountingRule(false);
      final route = RuleGuardedRoute(
        '1',
        rules: [const _NonCoordinatorAllowRule(), later],
      );
      expect(await route.popGuard(), isTrue);
      expect(later.callCount, 0);
    });

    test('false short-circuits later rules', () async {
      final later = _CountingRule(true);
      final route = RuleGuardedRoute(
        '1',
        rules: [const _NonCoordinatorBlockRule(), later],
      );
      expect(await route.popGuard(), isFalse);
      expect(later.callCount, 0);
    });

    test('async guardRule is awaited', () async {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _AsyncRule(false, delay: Duration(milliseconds: 5))],
      );
      expect(await route.popGuard(), isFalse);
    });
  });

  group('RouteGuardRule.popGuardWith chain', () {
    test('asserts when stackPath is null', () {
      final route = RuleGuardedRoute('1', rules: [const _ContinueRule()]);
      expect(
        () => route.popGuardWith(_UnusedCoordinator()),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts when coordinator mismatches', () {
      final expected = _UnusedCoordinator();
      final other = _UnusedCoordinator();
      final route = RuleGuardedRoute('1', rules: [const _ContinueRule()]);
      route.bindStackPath(_MockStackPath(coordinator: expected));

      expect(() => route.popGuardWith(other), throwsA(isA<AssertionError>()));
    });

    test('empty rules allow pop when coordinator matches', () async {
      final coordinator = _UnusedCoordinator();
      final route = RuleGuardedRoute('1', rules: []);
      route.bindStackPath(_MockStackPath(coordinator: coordinator));

      expect(await route.popGuardWith(coordinator), isTrue);
    });

    test('all-null With rules allow pop', () async {
      final coordinator = _UnusedCoordinator();
      final route = RuleGuardedRoute(
        '1',
        rules: [const _ContinueRule(), const _ContinueRule()],
      );
      route.bindStackPath(_MockStackPath(coordinator: coordinator));

      expect(await route.popGuardWith(coordinator), isTrue);
    });

    test('false from guardRuleWith blocks pop', () async {
      final coordinator = _UnusedCoordinator();
      final route = RuleGuardedRoute(
        '1',
        rules: [const _CoordinatorOnlyBlockRule()],
      );
      route.bindStackPath(_MockStackPath(coordinator: coordinator));

      expect(await route.popGuardWith(coordinator), isFalse);
      // Non-coordinator path still has no opinion.
      expect(await route.popGuard(), isTrue);
    });

    test('true from guardRuleWith allows and short-circuits', () async {
      final coordinator = _UnusedCoordinator();
      final later = _CountingWithRule(false);
      final route = RuleGuardedRoute(
        '1',
        rules: [const _CoordinatorOnlyAllowRule(), later],
      );
      route.bindStackPath(_MockStackPath(coordinator: coordinator));

      expect(await route.popGuardWith(coordinator), isTrue);
      expect(later.callCount, 0);
    });

    test('null continues to next With rule', () async {
      final coordinator = _UnusedCoordinator();
      final second = _CountingWithRule(false);
      final route = RuleGuardedRoute(
        '1',
        rules: [const _ContinueRule(), second],
      );
      route.bindStackPath(_MockStackPath(coordinator: coordinator));

      expect(await route.popGuardWith(coordinator), isFalse);
      expect(second.callCount, 1);
    });

    test('async guardRuleWith is awaited', () async {
      final coordinator = _UnusedCoordinator();
      final route = RuleGuardedRoute(
        '1',
        rules: [const _AsyncWithRule(true, delay: Duration(milliseconds: 5))],
      );
      route.bindStackPath(_MockStackPath(coordinator: coordinator));

      expect(await route.popGuardWith(coordinator), isTrue);
    });
  });
}

// =============================================================================
// Fakes
// =============================================================================

class _TestListenable implements ListenableMixin {
  final _listeners = <void Function()>[];

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  @override
  String toString() => '_TestListenable';
}

class _UnusedCoordinator implements CoordinatorCore<RouteUri> {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockStackPath implements StackPath<TestRoute> {
  _MockStackPath({this.coordinator});

  @override
  final CoordinatorCore? coordinator;

  @override
  TestRoute? get activeRoute => null;

  @override
  PathKey get pathKey => const PathKey('mock');

  @override
  List<TestRoute> get stack => const [];

  @override
  String? get debugLabel => null;

  @override
  CoordinatorCore? get proxyCoordinator => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void notifyListeners() {}

  @override
  void clear({RouteTarget? keep}) {}

  @override
  void bindStack(List<TestRoute> stack) {}

  @override
  void reset() {}

  @override
  Future<void> activateRoute(TestRoute route) async {}

  @override
  void dispose() {}
}

typedef VoidCallback = void Function();

// =============================================================================
// Rules
// =============================================================================

class _DefaultGuardRule extends GuardRule<TestRoute> {
  const _DefaultGuardRule();
}

class _FixedCanPopRule extends GuardRule<TestRoute> {
  const _FixedCanPopRule(this._canPop);

  final bool _canPop;

  @override
  bool canPopRule(covariant TestRoute route) => _canPop;
}

class _ListenableRule extends GuardRule<TestRoute> {
  _ListenableRule(this._listenable);

  final ListenableMixin _listenable;

  @override
  ListenableMixin? canPopListenableRule(covariant TestRoute route) =>
      _listenable;
}

class _CoordinatorCanPopRule extends GuardRule<TestRoute> {
  const _CoordinatorCanPopRule();

  @override
  bool canPopRuleWith(
    covariant CoordinatorCore coordinator,
    covariant TestRoute route,
  ) => false;
}

class _CoordinatorListenableRule extends GuardRule<TestRoute> {
  _CoordinatorListenableRule(this._listenable);

  final ListenableMixin _listenable;

  @override
  ListenableMixin? canPopListenableRuleWith(
    covariant CoordinatorCore coordinator,
    covariant TestRoute route,
  ) => _listenable;
}

class _NonCoordinatorBlockRule extends GuardRule<TestRoute> {
  const _NonCoordinatorBlockRule();

  @override
  FutureOr<bool?> guardRule(covariant TestRoute route) => false;
}

class _NonCoordinatorAllowRule extends GuardRule<TestRoute> {
  const _NonCoordinatorAllowRule();

  @override
  FutureOr<bool?> guardRule(covariant TestRoute route) => true;
}

class _CoordinatorOnlyAllowRule extends GuardRule<TestRoute> {
  const _CoordinatorOnlyAllowRule();

  @override
  FutureOr<bool?> guardRuleWith(
    covariant CoordinatorCore coordinator,
    covariant TestRoute route,
  ) => true;
}

class _CoordinatorOnlyBlockRule extends GuardRule<TestRoute> {
  const _CoordinatorOnlyBlockRule();

  @override
  FutureOr<bool?> guardRuleWith(
    covariant CoordinatorCore coordinator,
    covariant TestRoute route,
  ) => false;
}

class _ContinueRule extends GuardRule<TestRoute> {
  const _ContinueRule();

  @override
  FutureOr<bool?> guardRule(covariant TestRoute route) => null;
}

class _CountingRule extends GuardRule<TestRoute> {
  _CountingRule(this.result);

  final bool? result;
  int callCount = 0;

  @override
  FutureOr<bool?> guardRule(covariant TestRoute route) {
    callCount++;
    return result;
  }
}

class _CountingWithRule extends GuardRule<TestRoute> {
  _CountingWithRule(this.result);

  final bool? result;
  int callCount = 0;

  @override
  FutureOr<bool?> guardRuleWith(
    covariant CoordinatorCore coordinator,
    covariant TestRoute route,
  ) {
    callCount++;
    return result;
  }
}

class _AsyncRule extends GuardRule<TestRoute> {
  const _AsyncRule(this.result, {required this.delay});

  final bool? result;
  final Duration delay;

  @override
  Future<bool?> guardRule(covariant TestRoute route) async {
    await Future<void>.delayed(delay);
    return result;
  }
}

class _AsyncWithRule extends GuardRule<TestRoute> {
  const _AsyncWithRule(this.result, {required this.delay});

  final bool? result;
  final Duration delay;

  @override
  Future<bool?> guardRuleWith(
    covariant CoordinatorCore coordinator,
    covariant TestRoute route,
  ) async {
    await Future<void>.delayed(delay);
    return result;
  }
}
