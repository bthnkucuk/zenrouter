// ignore_for_file: invalid_use_of_protected_member

part of 'base.dart';

/// Mixin for stack paths that support mutable navigation operations.
///
/// Provides push/pop functionality for navigating between routes.
/// This mixin is applied to paths that need dynamic navigation.
mixin StackMutatable<T extends RouteTarget> on StackPath<T>
    implements StackNavigatable<T> {
  /// Tail of the mutation chain, or `null` when no mutation is in flight.
  ///
  /// Kept null while idle so an uncontended mutation starts synchronously.
  /// Callers cannot await [push] — it settles on pop, not on navigation — so
  /// they fire it and expect the stack to reflect it as soon as the redirect
  /// pipeline yields. Chaining onto an already-completed future would insert
  /// an extra microtask and break that expectation.
  Future<void>? _pending;

  /// Runs [task] after every mutation already queued on this path.
  ///
  /// Stack mutations are not atomic: every one of them awaits something before
  /// touching the stack ([RouteRedirect.resolve] on the push side,
  /// [RouteGuard.popGuard] on the pop side). Without serialization a mutation
  /// arriving during one of those gaps observes — and corrupts — a stack that
  /// is mid-flight. The canonical failure: a push landing while a pop guard is
  /// showing a confirmation dialog makes [pop] remove the newly pushed route
  /// instead of the one the guard approved, bypassing that route's own guard.
  ///
  /// Only the mutating region of an operation belongs here. In particular
  /// [push] must not enqueue its result await, which does not complete until
  /// the route is popped — that would hold the queue for the entire lifetime of
  /// the route on screen.
  Future<R> _enqueue<R>(Future<R> Function() task) {
    final pending = _pending;
    // Idle: run now, so serialization costs nothing when nothing is in flight.
    final next = pending == null ? task() : pending.then((_) => task());

    late final Future<void> tail;
    tail = next.then<void>((_) {}, onError: (_) {}).then((_) {
      // Drop the chain once it drains, so the next mutation starts eagerly
      // again. Guarded: a mutation queued meanwhile owns the tail now.
      if (identical(_pending, tail)) _pending = null;
    });
    _pending = tail;
    return next;
  }

  /// Adds a new route to the top of the stack.
  ///
  /// Resolves redirects via [RouteRedirect.resolve] before pushing.
  /// Returns a future that completes when the popped route provides a result.
  Future<R?> push<R extends Object>(T element) async {
    final target = await _enqueue(() => _pushLocked(element));
    if (target == null) return null;

    // Deliberately outside the queue: this settles on pop, not on navigation.
    // ignore: invalid_use_of_visible_for_testing_member
    return await target.onResult.future as R?;
  }

  /// The mutating half of [push]. Must only run from inside [_enqueue].
  Future<T?> _pushLocked(T element) async {
    T? target = await RouteRedirect.resolve(element, coordinator);
    if (target == null) return null;

    assert(
      !_stack.any((route) => identical(route, target)),
      'Route instance $target is already on this path.\n'
      'A RouteTarget owns one path binding and one result completer, so it maps '
      'to exactly one stack entry. Pushing it twice makes both push futures '
      'share a completer and unbinds the surviving entry.\n'
      'Push a new instance instead: two equal-but-distinct routes are supported.',
    );

    target.isPopByPath = false;
    target.bindStackPath(this);
    _stack.add(target);
    notifyListeners();
    return target;
  }

  /// Replaces the current route with a new one.
  ///
  /// Behavior depends on stack state:
  /// - Empty stack: Pushes the new route normally
  /// - Single element: Completes active route, resets, then pushes new route
  /// - Multiple elements: Pops top route (respecting guards), then pushes new route
  ///
  /// Returns null if redirect resolution fails or guard blocks the pop.
  Future<R?> pushReplacement<R extends Object, RO extends Object>(
    T element, {
    RO? result,
  }) async {
    T? target = await RouteRedirect.resolve(element, coordinator);
    if (target == null) return null;

    final activeRoute = this.activeRoute;
    if (activeRoute case final activeRoute?) {
      if (stack.length == 1) {
        activeRoute.completeOnResult(result, coordinator);
        activeRoute.onDiscard();
        reset();
        return push(target);
      }

      final popped = await pop(result);
      if (popped == null || !popped) return null;
      // ignore: invalid_use_of_visible_for_testing_member
      await activeRoute.onResult.future;
      return push(target);
    }

    return push(target);
  }

  /// Adds a route to the top, or moves it to the top if already in stack.
  ///
  /// If the route exists in the stack, it's moved to the top position.
  /// If not, it's pushed as a new entry. Useful for tab navigation.
  Future<void> pushOrMoveToTop(T element) =>
      _enqueue(() => _pushOrMoveToTopLocked(element));

  /// The mutating body of [pushOrMoveToTop]. Only runs from inside [_enqueue].
  Future<void> _pushOrMoveToTopLocked(T element) async {
    T? target = await RouteRedirect.resolve(element, coordinator);
    if (target == null) return;

    target.isPopByPath = false;
    target.bindStackPath(this);
    final index = _stack.indexOf(target);
    if (_stack.isNotEmpty && index == _stack.length - 1) {
      final last = _stack.last;
      last.onUpdate(target);
      if (!last.deepEquals(target)) {
        target.onDiscard();
        target.clearStackPath();
      }
      return;
    }

    if (index != -1) {
      final removed = _stack.removeAt(index);
      if (!removed.deepEquals(target)) {
        removed.onDiscard();
        removed.clearStackPath();
      }
    }
    _stack.add(target);
    notifyListeners();
  }

  /// Removes the top route from the stack.
  ///
  /// Consults [RouteGuard] before removing. Unlike [remove], this only
  /// operates on the top route and respects guard logic.
  ///
  /// Returns:
  /// - `true`: Pop completed successfully
  /// - `false`: Guard blocked the pop
  /// - `null`: Stack was empty
  Future<bool?> pop([Object? result]) {
    final last = _stack.isEmpty ? null : _stack.last;
    if (_pending == null && last is! RouteGuard) {
      // No guard to consult means no await gap, so there is nothing another
      // mutation could interleave into and nothing to serialize. Apply now, so
      // a burst of fire-and-forget pops still lands synchronously.
      return Future<bool?>.value(_popApply(result));
    }
    return _enqueue(() => _popLocked(result));
  }

  /// The mutating body of [pop]. Must only run from inside [_enqueue].
  Future<bool?> _popLocked([Object? result]) async {
    if (_stack.isEmpty) return null;

    final last = _stack.last;
    if (last is RouteGuard) {
      final canPop = await switch (coordinator) {
        null => last.popGuard(),
        final coordinator => last.popGuardWith(coordinator),
      };
      if (!canPop) return false;

      // The guard above awaited. Queued mutations cannot have run in that gap,
      // but [remove] is synchronous and unqueued — the widget layer calls it
      // while handling a platform pop. Only ever remove the route the guard
      // actually approved.
      if (_stack.isEmpty || !identical(_stack.last, last)) return null;
    }

    return _popApply(result);
  }

  /// Removes the top route unconditionally. Guards are the caller's business.
  bool? _popApply(Object? result) {
    if (_stack.isEmpty) return null;
    final element = _stack.removeLast();
    element.isPopByPath = true;
    element.bindResultValue(result);
    notifyListeners();
    return true;
  }

  /// Removes a specific route from any position in the stack.
  ///
  /// Unlike [pop], this bypasses guards and operates on any index.
  /// Used for system-initiated removals or forced cleanup.
  void remove(T element, {bool discard = true}) {
    final removed = _stack.remove(element);
    if (removed) {
      if (discard) element.onDiscard();
      element.clearStackPath();
      notifyListeners();
    }
  }

  @override
  Future<void> navigate(T route) => _enqueue(() => _navigateLocked(route));

  /// The mutating body of [navigate]. Must only run from inside [_enqueue].
  ///
  /// Calls the locked primitives rather than the public ones: those enqueue,
  /// and enqueueing from inside a queued task would wait on the queue this
  /// task is itself holding.
  Future<void> _navigateLocked(T route) async {
    T? target = await RouteRedirect.resolve(route, coordinator);
    if (target == null) return;

    final routeIndex = stack.indexOf(target);
    if (routeIndex != -1) {
      while (stack.length > routeIndex + 1) {
        final allowPop = await _popLocked();
        if (allowPop == null || !allowPop) {
          notifyListeners();
          return;
        }
      }

      final existingRoute = stack[routeIndex];
      existingRoute.onUpdate(target);
      notifyListeners();

      if (!existingRoute.deepEquals(target)) {
        target.onDiscard();
      }
    } else {
      // Deliberately not the public [push]: that would enqueue behind the task
      // we are currently running, and it settles on pop rather than on
      // navigation being applied.
      await _pushLocked(target);
    }
  }
}
