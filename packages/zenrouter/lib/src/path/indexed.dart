// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter/widgets.dart';
import 'package:zenrouter/src/coordinator/base.dart';
import 'package:zenrouter/src/path/restoration.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

/// A fixed stack path for indexed navigation (like tabs).
///
/// Routes are pre-defined and cannot be added or removed. Navigation switches
/// the active index.
///
/// ## Role in Navigation Flow
///
/// [IndexedStackPath] manages tab-based navigation:
/// 1. Routes are defined upfront in a fixed list
/// 2. Navigation switches the active index rather than stack
/// 3. Renders content via [IndexedStackPathBuilder] widget
/// 4. Implements [RestorablePath] for tab index restoration
///
/// When navigating:
/// - [goToIndexed] switches to a different route by index
/// - [activateRoute] activates a route already in the stack
/// - Routes cannot be pushed or popped, only activated
class IndexedStackPath<T extends RouteTarget> extends StackPath<T>
    with StackNavigatable<T>, RestorablePath<T, int, int>, ChangeNotifier {
  IndexedStackPath._(
    super.stack, {
    super.debugLabel,
    super.coordinator,
    this.lazy = false,
    this.pauseHiddenTabs = false,
  }) : assert(stack.isNotEmpty, 'Read-only path must have at least one route'),
       super() {
    for (final path in stack) {
      /// Set the output of every route to null since this cannot pop
      path.completeOnResult(null, null);
      path.bindStackPath(this);
    }
  }

  /// Creates an [IndexedStackPath] with a fixed list of routes.
  ///
  /// This is the standard way to create a fixed stack for indexed navigation.
  factory IndexedStackPath.create(
    List<T> stack, {
    String? label,
    Coordinator? coordinator,
    bool lazy = false,
    bool pauseHiddenTabs = false,
  }) => IndexedStackPath._(
    stack,
    debugLabel: label,
    coordinator: coordinator,
    lazy: lazy,
    pauseHiddenTabs: pauseHiddenTabs,
  );

  /// Creates an [IndexedStackPath] associated with a [Coordinator].
  ///
  /// This constructor binds the path to a specific coordinator, allowing it to
  /// interact with the coordinator for navigation actions.
  factory IndexedStackPath.createWith(
    List<T> stack, {
    required Coordinator coordinator,
    required String label,
    bool lazy = false,
    bool pauseHiddenTabs = false,
  }) => IndexedStackPath._(
    stack,
    debugLabel: label,
    coordinator: coordinator,
    lazy: lazy,
    pauseHiddenTabs: pauseHiddenTabs,
  );

  /// Whether a tab is built only once it has been visited.
  ///
  /// Off by default, which is what an indexed stack normally means: every tab
  /// is built up front, so switching costs nothing and every tab's `initState`
  /// runs at startup.
  ///
  /// Turning it on defers a tab's widgets — and whatever their `initState` does:
  /// analytics, prefetching, subscriptions — until the tab is first shown. From
  /// then on it is kept alive exactly as before, with its state intact across
  /// further switches.
  ///
  /// It is a behaviour change, which is why it is opt-in: a tab that counted on
  /// doing work at startup will not. Nothing else moves — the tabs, their order
  /// and their state once visited are the same. It is not a rendering
  /// optimisation either; Flutter already skips paint, hit-testing and
  /// semantics for hidden tabs.
  ///
  /// See also [pauseHiddenTabs], which is about a tab that *is* built.
  final bool lazy;

  /// Whether a tab stops ticking while it is off screen.
  ///
  /// Off by default, matching Flutter: `IndexedStack` keeps every child
  /// ticking, so an animation in a tab the user cannot see goes on rebuilding
  /// it on every frame for as long as the app runs. That is usually the largest
  /// standing cost of a tab shell, and [lazy] does not address it — a tab that
  /// has been visited once stays mounted and ticking.
  ///
  /// Turning it on wraps each hidden tab in a disabled `TickerMode`. Two
  /// consequences follow, and they are the reason this is not the default:
  ///
  /// - An animation **in flight** when the tab leaves freezes where it was and
  ///   resumes on return, instead of finishing off screen.
  /// - `await controller.forward()` does not complete while the tab is hidden.
  ///   A tab that awaits an animation before doing something else waits for the
  ///   user to come back.
  ///
  /// So it suits tabs whose animations are decoration, and not tabs that drive
  /// logic from them.
  final bool pauseHiddenTabs;

  /// The key used to identify this type in [defineLayoutBuilder].
  static const key = PathKey('IndexedStackPath');

  /// IndexedStackPath key. This is used to identify this type in [defineLayoutBuilder].
  @override
  PathKey get pathKey => key;

  int _activeIndex = 0;

  /// The index of the currently active path in the stack.
  int get activeIndex => _activeIndex;

  @override
  T get activeRoute => stack[activeIndex];

  /// Switches the active route to the one at [index].
  ///
  /// Handles guards on the current route and redirects on the new route.
  Future<void> goToIndexed(int index) async {
    if (index >= stack.length || index < 0) {
      throw StateError('Index out of bounds');
    }

    /// Ignore already active index
    if (index == _activeIndex) return;

    final oldIndex = _activeIndex;
    final oldRoute = stack[oldIndex];
    if (oldRoute is RouteGuard) {
      final guard = oldRoute as RouteGuard;
      final canPop = await switch (coordinator) {
        null => guard.popGuard(),
        final coordinator => guard.popGuardWith(coordinator),
      };
      if (!canPop) return;
    }
    var newRoute = stack[index];
    while (newRoute is RouteRedirect) {
      final routeRedirect = newRoute as RouteRedirect;
      final redirectTo = await switch (coordinator) {
        null => routeRedirect.redirect(),
        final coordinator => routeRedirect.redirectWith(coordinator),
      };
      assert(
        redirectTo == null || redirectTo is T,
        'Redirected route must be the same type as the stack route',
      );
      if (redirectTo == null) return;
      if (identical(redirectTo, newRoute)) break;
      newRoute = redirectTo as T;
    }

    final newIndex = stack.indexOf(newRoute);
    // Not found
    if (newIndex == -1) return;
    _activeIndex = newIndex;
    notifyListeners();
  }

  @override
  Future<void> activateRoute(T route) async {
    final index = stack.indexOf(route);
    if (index == -1) {
      route.onDiscard();
      throw StateError('Route not found');
    }

    final indexRoute = stack[index];

    /// Update the existing route with new state
    indexRoute.onUpdate(route);

    if (!indexRoute.deepEquals(route)) {
      route.onDiscard();
    }

    if (index == _activeIndex) {
      // Already the active tab, so there is no switch to announce — but it was
      // just handed new data, and without this nothing tells anyone: not the
      // renderer, and not the router, which never re-reads the URI and so
      // leaves the address bar on the old query.
      //
      // A distinct instance is what "handed new data" means, and it is the same
      // test `pushOrMoveToTop` uses for this situation. Being handed *itself* —
      // which is what resolving a layout does — transfers nothing and stays
      // silent.
      if (!indexRoute.deepEquals(route)) notifyListeners();
      return;
    }
    await goToIndexed(index);
  }

  @override
  void reset() {
    _activeIndex = 0;
    notifyListeners();
  }

  /// Releases this path and everything still waiting on it.
  ///
  /// See [NavigationPath.dispose] for the reasoning, including why this lives
  /// on the concrete path rather than on [StackPath].
  @override
  void dispose() {
    for (final route in stack) {
      route.completeOnResult(null, null, true);
      route.clearStackPath();
    }
    super.dispose();
  }

  @override
  void restore(int data) {
    assert(data >= 0 && data < stack.length, 'Index out of bounds');
    _activeIndex = data;
  }

  @override
  int serialize() => _activeIndex;

  @override
  int deserialize(int data) => data;

  @override
  Future<void> navigate(T route) async {
    final routeIndex = stack.indexOf(route);
    if (routeIndex == -1) {
      // Route not found in IndexedStackPath - restore the URL to current state
      notifyListeners();
      return;
    }
    await activateRoute(route);
  }
}
