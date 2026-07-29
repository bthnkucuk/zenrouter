import 'dart:async';

import 'package:zenrouter_core/src/coordinator/base.dart';
import 'package:zenrouter_core/src/internal/reactive.dart';
import 'package:zenrouter_core/src/mixin/guard.dart';
import 'package:zenrouter_core/src/mixin/target.dart';
import 'package:zenrouter_core/src/mixin/uri.dart';

/// Base class for composable pop-guard logic.
///
/// Guard rules extract leave-confirmation logic from routes into reusable,
/// testable components. Rules are executed in order until one returns a
/// non-null result.
///
/// ## Coordinator vs non-coordinator
///
/// Prefer the non-`With` methods when the rule only needs the [route]:
/// [canPopRule], [canPopListenableRule], [guardRule].
///
/// Override the `With` variants when the decision needs a
/// [CoordinatorCore] (dialogs via navigator context, shared app state, etc.).
/// By default, each `With` method delegates to its non-`With` counterpart.
///
/// ## Role in Navigation Flow
///
/// When a [RouteGuardRule] route is about to be popped:
///
/// 1. [RouteGuard.popGuard] / [RouteGuard.popGuardWith] iterates through
///    [RouteGuardRule.guardRules]
/// 2. Each rule's [guardRule] / [guardRuleWith] is called in sequence
/// 3. Based on the result:
///    - `null`: Next rule is processed
///    - `false`: Pop is blocked, stack unchanged
///    - `true`: Pop is allowed, chain stops
/// 4. If every rule returns `null`, the pop is allowed
///
/// Rules can be composed for complex scenarios: unsaved-changes prompts,
/// permission checks, logging, etc.
abstract class GuardRule<T extends RouteTarget> {
  const GuardRule();

  /// Sync hint for [RouteGuard.canPop] when no coordinator is available.
  ///
  /// Return `false` to force `PopScope` interception. Default `true` means
  /// this rule does not require interception on its own.
  /// [RouteGuardRule.canPop] is `true` only when every rule returns `true`.
  bool canPopRule(covariant T route) => true;

  /// Optional [ListenableMixin] that invalidates [canPop] for [route].
  ListenableMixin? canPopListenableRule(covariant T route) => null;

  /// Determines whether the pop should proceed for [route] without a
  /// coordinator.
  ///
  /// Return `null` to continue to the next rule.
  /// Return `true` to allow the pop (stops the chain).
  /// Return `false` to block the pop (stops the chain).
  ///
  /// Defaults to `null` (no opinion) so rules that only override
  /// [guardRuleWith] still continue correctly on the non-coordinator path.
  FutureOr<bool?> guardRule(covariant T route) => null;

  /// Sync hint for [RouteGuard.canPopWith].
  ///
  /// Defaults to [canPopRule].
  bool canPopRuleWith(
    covariant CoordinatorCore coordinator,
    covariant T route,
  ) => canPopRule(route);

  /// Optional [ListenableMixin] for [RouteGuard.canPopListenableWith].
  ///
  /// Defaults to [canPopListenableRule].
  ListenableMixin? canPopListenableRuleWith(
    covariant CoordinatorCore coordinator,
    covariant T route,
  ) => canPopListenableRule(route);

  /// Determines whether the pop should proceed for [route] with [coordinator].
  ///
  /// Return `null` to continue to the next rule.
  /// Return `true` to allow the pop (stops the chain).
  /// Return `false` to block the pop (stops the chain).
  ///
  /// Defaults to [guardRule].
  FutureOr<bool?> guardRuleWith(
    covariant CoordinatorCore coordinator,
    covariant T route,
  ) => guardRule(route);
}

/// Mixin for routes that use a list of guard rules.
///
/// Routes with this mixin delegate their pop-guard logic to a list of
/// [GuardRule] instances, enabling composable and testable guard chains.
///
/// Non-coordinator APIs ([canPop], [canPopListenable], [popGuard]) call the
/// non-`With` rule methods. Coordinator-aware APIs call the `With` variants.
mixin RouteGuardRule<T extends RouteTarget> on RouteTarget
    implements RouteGuard {
  /// The list of rules applied to this route, in order.
  ///
  /// Rules are processed sequentially. The first non-null result wins.
  List<GuardRule> get guardRules;

  @override
  bool get canPop => guardRules.every((rule) => rule.canPopRule(this as T));

  @override
  bool canPopWith(covariant CoordinatorCore<RouteUri> coordinator) =>
      guardRules.every((rule) => rule.canPopRuleWith(coordinator, this as T));

  @override
  ListenableMixin? get canPopListenable {
    final listenables = <ListenableMixin>[
      for (final rule in guardRules)
        if (rule.canPopListenableRule(this as T) case final listenable?)
          listenable,
    ];
    return switch (listenables) {
      [] => null,
      [final only] => only,
      _ => ListenableMixin.merge(listenables),
    };
  }

  @override
  ListenableMixin? canPopListenableWith(
    covariant CoordinatorCore<RouteUri> coordinator,
  ) {
    final listenables = <ListenableMixin>[
      for (final rule in guardRules)
        if (rule.canPopListenableRuleWith(coordinator, this as T)
            case final listenable?)
          listenable,
    ];
    return switch (listenables) {
      [] => null,
      [final only] => only,
      _ => ListenableMixin.merge(listenables),
    };
  }

  @override
  FutureOr<bool> popGuard() async {
    for (final rule in guardRules) {
      final result = await rule.guardRule(this as T);
      if (result != null) return result;
    }
    return true;
  }

  /// Implements [RouteGuard.popGuardWith] by running all rules in sequence.
  ///
  /// Processing stops when any rule returns a non-null [bool].
  /// If all rules return `null`, the pop is allowed.
  @override
  FutureOr<bool> popGuardWith(covariant CoordinatorCore coordinator) async {
    assert(stackPath?.coordinator == coordinator, '''
[RouteGuard] The path [${stackPath.toString()}] is associated with a different coordinator (or null) than the one currently handling the navigation.
Expected coordinator: $coordinator
Path's coordinator: ${stackPath?.coordinator}
Ensure that the path is created with the correct coordinator using `.createWith()` and that routes are being managed by the correct coordinator.
''');

    for (final rule in guardRules) {
      final result = await rule.guardRuleWith(coordinator, this as T);
      if (result != null) return result;
    }
    return true;
  }
}
