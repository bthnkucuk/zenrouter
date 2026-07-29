import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

class TestRoute extends RouteTarget {
  TestRoute(this.id);
  final String id;

  @override
  List<Object?> get props => [id];
}

class RuleGuardedRoute extends TestRoute with RouteGuardRule<TestRoute> {
  RuleGuardedRoute(super.id, {required this.rules});

  final List<GuardRule> rules;

  @override
  List<GuardRule> get guardRules => rules;
}

void main() {
  group('RouteGuardRule', () {
    test('popGuard defaults to true', () async {
      final route = RuleGuardedRoute('1', rules: []);
      expect(await route.popGuard(), isTrue);
    });

    test('implements RouteGuard', () {
      final route = RuleGuardedRoute('1', rules: []);
      expect(route, isA<RouteGuard>());
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

    test('canPopListenable is null when no rules expose one', () {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _FixedCanPopRule(true)],
      );
      expect(route.canPopListenable, isNull);
    });

    test('canPopListenable returns single listenable', () {
      final notifier = _TestListenable();
      final route = RuleGuardedRoute('1', rules: [_ListenableRule(notifier)]);
      expect(route.canPopListenable, same(notifier));
    });

    test('canPopListenable merges multiple listenables', () {
      final a = _TestListenable();
      final b = _TestListenable();
      final route = RuleGuardedRoute(
        '1',
        rules: [_ListenableRule(a), _ListenableRule(b)],
      );
      expect(route.canPopListenable, isA<ListenableMixin>());
      expect(route.canPopListenable, isNot(same(a)));
      expect(route.canPopListenable, isNot(same(b)));

      var notified = 0;
      route.canPopListenable!.addListener(() => notified++);
      a.notify();
      b.notify();
      expect(notified, 2);
    });

    test('popGuard runs guardRule without coordinator', () async {
      final route = RuleGuardedRoute(
        '1',
        rules: [const _NonCoordinatorBlockRule()],
      );
      expect(await route.popGuard(), isFalse);
    });

    test('default guardRule is null so chain continues', () async {
      final rule = const _FixedCanPopRule(true);
      expect(await rule.guardRule(TestRoute('1')), isNull);
    });

    test('With methods default to non-With counterparts', () async {
      final route = TestRoute('1');
      final rule = const _NonCoordinatorBlockRule();

      // canPopRuleWith / canPopListenableRuleWith / guardRuleWith
      // fall back when not overridden.
      expect(rule.canPopRule(route), isTrue);
      expect(rule.canPopListenableRule(route), isNull);
      expect(await rule.guardRule(route), isFalse);
    });

    test('guardRuleWith can override without changing guardRule', () async {
      final route = TestRoute('1');
      final rule = const _CoordinatorOnlyAllowRule();

      expect(await rule.guardRule(route), isNull);
      // Call With via a typed cast to avoid standing up a full coordinator.
      expect(
        await rule.guardRuleWith(_UnusedCoordinator(), route),
        isTrue,
      );
    });

    test('canPopRuleWith can differ from canPopRule', () {
      final route = TestRoute('1');
      final rule = const _CoordinatorCanPopRule();

      expect(rule.canPopRule(route), isTrue);
      expect(rule.canPopRuleWith(_UnusedCoordinator(), route), isFalse);

      final guarded = RuleGuardedRoute('1', rules: [rule]);
      expect(guarded.canPop, isTrue);
      expect(guarded.canPopWith(_UnusedCoordinator()), isFalse);
    });
  });
}

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
}

/// Minimal stand-in so typed `CoordinatorCore` parameters compile in tests.
class _UnusedCoordinator implements CoordinatorCore<RouteUri> {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

class _NonCoordinatorBlockRule extends GuardRule<TestRoute> {
  const _NonCoordinatorBlockRule();

  @override
  FutureOr<bool?> guardRule(covariant TestRoute route) => false;
}

class _CoordinatorOnlyAllowRule extends GuardRule<TestRoute> {
  const _CoordinatorOnlyAllowRule();

  @override
  FutureOr<bool?> guardRuleWith(
    covariant CoordinatorCore coordinator,
    covariant TestRoute route,
  ) => true;
}
