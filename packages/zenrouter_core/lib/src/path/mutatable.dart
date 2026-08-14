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

  /// Records, on the coordinator, whether the commit about to be notified
  /// should overwrite the current browser history entry or add one.
  ///
  /// Every notifying mutation calls this, so the value read at report time —
  /// a post-frame callback — always describes the commit that triggered it.
  void _markHistory({required bool replaces}) {
    coordinator?.replacesHistoryEntry = replaces;
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
  Future<T?> _pushLocked(T element, {bool replacesHistory = false}) async {
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
    _markHistory(replaces: replacesHistory);
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
        return _pushReplacing(target);
      }

      final popped = await _pop(result, replacesHistory: true);
      if (popped == null || !popped) return null;
      // ignore: invalid_use_of_visible_for_testing_member
      await activeRoute.onResult.future;
      return _pushReplacing(target);
    }

    return _pushReplacing(target);
  }

  /// Pushes [target] as a replacement: the commit overwrites the current
  /// browser history entry rather than adding one.
  ///
  /// The queue holds only the mutation, never the result await — that settles
  /// on pop and would pin the queue for the route's whole life on screen.
  Future<R?> _pushReplacing<R extends Object>(T target) async {
    final pushed = await _enqueue(
      () => _pushLocked(target, replacesHistory: true),
    );
    if (pushed == null) return null;
    // ignore: invalid_use_of_visible_for_testing_member
    return await pushed.onResult.future as R?;
  }

  /// Activates [route] as the only entry, overwriting the current history
  /// entry instead of adding one. Used by `CoordinatorCore.replace`.
  Future<void> activateReplacing(T route) async {
    // `clear` rather than `reset` so the route being re-pushed is spared the
    // discard — it is often the layout instance already on this path.
    clear(keep: route);
    await _enqueue(() => _pushLocked(route, replacesHistory: true));
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
    assert(
      index == -1
          ? _debugCheckNoMatch('pushOrMoveToTop', target)
          : _debugCheckMatch('pushOrMoveToTop', _stack[index], target),
    );
    if (_stack.isNotEmpty && index == _stack.length - 1) {
      final last = _stack.last;
      last.onUpdate(target);
      if (!last.deepEquals(target)) {
        target.onDiscard();
        target.clearStackPath();
        // A distinct instance arrived, so [onUpdate] may have carried new data
        // onto the route that stays. The stack looks unchanged and nothing
        // else would tell the UI. Handing in the very same instance really is
        // a no-op and stays silent.
        _markHistory(replaces: false);
        notifyListeners();
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
    _markHistory(replaces: false);
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
  Future<bool?> pop([Object? result]) => _pop(result);

  Future<bool?> _pop(Object? result, {bool replacesHistory = false}) {
    final last = _stack.isEmpty ? null : _stack.last;
    if (_pending == null && last is! RouteGuard) {
      // No guard to consult means no await gap, so there is nothing another
      // mutation could interleave into and nothing to serialize. Apply now, so
      // a burst of fire-and-forget pops still lands synchronously.
      return Future<bool?>.value(
        _popApply(result, replacesHistory: replacesHistory),
      );
    }
    return _enqueue(
      () => _popLocked(result, replacesHistory: replacesHistory),
    );
  }

  /// The mutating body of [pop]. Must only run from inside [_enqueue].
  Future<bool?> _popLocked(
    Object? result, {
    bool replacesHistory = false,
  }) async {
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

    return _popApply(result, replacesHistory: replacesHistory);
  }

  /// Removes the top route unconditionally. Guards are the caller's business.
  bool? _popApply(Object? result, {bool replacesHistory = false}) {
    if (_stack.isEmpty) return null;
    final element = _stack.removeLast();
    element.isPopByPath = true;
    element.bindResultValue(result);
    _markHistory(replaces: replacesHistory);
    notifyListeners();
    return true;
  }

  /// Replaces the whole stack with [next] in a single commit.
  ///
  /// Routes carried over from the current stack keep their identity, their
  /// result completer and their widget state; routes that are not in [next] are
  /// discarded and unbound. Exactly one notification is emitted.
  ///
  /// This is the primitive for declarative updates, where the caller already
  /// knows the target stack. Rebuilding a path as `reset()` followed by a
  /// `push` per route looks equivalent but is not: `reset` completes the result
  /// completer of *every* route including the ones that survive, and each push
  /// notifies separately.
  ///
  /// Guards are not consulted — the caller declared the target stack.
  void applyStack(List<T> next) {
    final dropped = [
      for (final route in _stack)
        if (!next.any((n) => identical(n, route))) route,
    ];

    bindStack(next);

    for (final route in dropped) {
      route.onDiscard();
      route.clearStackPath();
    }

    _markHistory(replaces: false);
    notifyListeners();
  }

  /// Debug-only check that `props` actually distinguishes routes.
  ///
  /// [navigate] and [pushOrMoveToTop] find an existing entry with `indexOf`,
  /// which compares by value — that is, by `props`. When `props` omits a field
  /// the route is identified by, two different destinations compare equal and
  /// the match silently lands on the wrong one: a deep link to `/order/8123`
  /// leaves you on `/order/5500`, and the URL is corrected back to match.
  ///
  /// Routes carry a URI already, so the mistake is detectable: a match whose
  /// path differs from the target's cannot be the same destination.
  ///
  /// Only the path is compared. Query strings are excluded on purpose —
  /// [RouteQueryParameters] exists so a route keeps its identity while its
  /// queries change, and such a match is then updated in place rather than
  /// being a mistake.
  bool _debugCheckMatch(String operation, T matched, T target) {
    if (matched is! RouteUri || target is! RouteUri) return true;
    if (matched.identifier.path == target.identifier.path) return true;

    throw AssertionError(
      '$operation matched a route with a different URI.\n'
      '  asked for  ${target.identifier}\n'
      '  matched    ${matched.identifier}\n'
      'They compare equal, so `props` does not tell these destinations apart. '
      'Add the fields that do — usually the ones interpolated into toUri():\n'
      '  @override\n'
      '  List<Object?> get props => [id];',
    );
  }

  /// Debug-only mirror of [_debugCheckMatch]: no entry compared equal, yet one
  /// on the stack has the very same URI — queries included, so two genuinely
  /// different destinations that share a path are not flagged. `props` then
  /// holds per-instance state, and a route that should have been moved to the
  /// top is pushed again.
  bool _debugCheckNoMatch(String operation, T target) {
    if (target is! RouteUri) return true;
    for (final route in _stack) {
      if (route is! RouteUri) continue;
      if (route.identifier != target.identifier) continue;
      throw AssertionError(
        '$operation found no match for ${target.identifier}, but a route with '
        'that exact URI is already on the stack.\n'
        'They compare unequal, so `props` holds state that differs per '
        'instance — a completer, a callback, a timestamp. Keep `props` to the '
        'values that identify the destination.',
      );
    }
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
      _markHistory(replaces: false);
      notifyListeners();
    }
  }

  /// Removes [element] itself, matching on identity rather than value.
  ///
  /// [remove] matches with `==`, so on a stack that legitimately holds the same
  /// route twice — `[/edit, /settings, /edit]` — it removes the *first* equal
  /// entry, which is not necessarily the one the caller means. Callers that
  /// know exactly which live entry left, such as the [Navigator] reporting a
  /// removed page, must target it by identity.
  ///
  /// A no-op when [element] is not on the stack, so it is safe to call for a
  /// route that some other path already removed.
  void removeIdentical(T element, {bool discard = true}) {
    final index = _stack.indexWhere((route) => identical(route, element));
    if (index == -1) return;

    _stack.removeAt(index);
    if (discard) element.onDiscard();
    element.clearStackPath();
    _markHistory(replaces: false);
    notifyListeners();
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
      assert(_debugCheckMatch('navigate', stack[routeIndex], target));
      while (stack.length > routeIndex + 1) {
        final allowPop = await _popLocked(null);
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
