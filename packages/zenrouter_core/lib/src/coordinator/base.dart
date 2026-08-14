import 'dart:async';

import 'package:meta/meta.dart';
import 'package:zenrouter_core/src/coordinator/modular.dart';

import 'package:zenrouter_core/src/internal/equatable.dart';
import 'package:zenrouter_core/src/internal/reactive.dart';
import 'package:zenrouter_core/src/mixin/deeplink.dart';
import 'package:zenrouter_core/src/mixin/layout.dart';
import 'package:zenrouter_core/src/mixin/redirect.dart';
import 'package:zenrouter_core/src/mixin/uri.dart';
import 'package:zenrouter_core/src/path/base.dart';
import 'package:zenrouter_core/src/path/navigatable.dart';

enum _ResolveLayoutStrategy { pushToTop, override }

/// The central hub for navigation state and operations in ZenRouter.
///
/// [CoordinatorCore] manages navigation state, coordinates between paths,
/// handles deep links, and integrates all routing components.
///
/// ## Role in Navigation Flow
///
/// When a navigation operation occurs:
///
/// 1. [push], [replace], or [navigate] is called with a route
/// 2. [RouteRedirect.resolve] processes any redirects
/// 3. Layout hierarchy is resolved via [RouteLayoutParent.resolveParentLayout]
/// 4. Route is pushed/popped on the appropriate [StackPath]
/// 5. Listeners are notified, triggering UI rebuilds
///
/// ## Navigation Methods
///
/// - [push]: Adds route to stack - standard forward navigation
/// - [pop]: Removes top route - back navigation
/// - [replace]: Clears stack, sets single route - reset state
/// - [navigate]: Smart navigation - pops to existing or pushes new
/// - [recover]: Deep link handling respecting [RouteDeepLink] strategy
abstract class CoordinatorCore<T extends RouteUri> extends Equatable
    with ListenableObject
    implements RouteModule<T> {
  CoordinatorCore({this.initialRoutePath}) {
    for (final path in paths) {
      path.addListener(notifyListeners);
    }
    init();
  }

  /// {@macro zenrouter.coordinator.modular.coordinator}
  @override
  CoordinatorModular<T> get coordinator => throw UnimplementedError(
    'This coordinator is standalone and does not belong to any [CoordinatorModular] \n'
    'If you want to make it a part of a [CoordinatorModular] you should override `coordinator` getter or passing it through constructor',
  );

  /// The [rootCoordinator] coordinator return a top level coordinator which used as [routeConfig].
  ///
  /// If this coordinator is a part of another [CoordinatorModular], it will return the [coordinator].
  /// Otherwise, it will return itself.
  late final CoordinatorCore<T> rootCoordinator = isRouteModule
      ? coordinator
      : this;

  bool _replacesHistoryEntry = false;

  /// Whether the most recent commit should overwrite the current browser
  /// history entry instead of adding one.
  ///
  /// Set by every mutation as it commits — replacements write `true`, ordinary
  /// navigation writes `false` — and read when the router reports the new URI.
  /// Reading it at report time is what makes this work: the report happens in a
  /// post-frame callback, long after the mutation, so a synchronous
  /// `Router.neglect` around the call cannot capture the intent.
  ///
  /// Framework-managed. Assign only from a path committing a mutation.
  bool get replacesHistoryEntry => _replacesHistoryEntry;
  set replacesHistoryEntry(bool value) => _replacesHistoryEntry = value;

  @override
  void dispose() {
    for (final path in paths) {
      path.removeListener(notifyListeners);
      path.dispose();
    }
    super.dispose();
  }

  /// Whether this coordinator is a part of a [CoordinatorModular].
  ///
  /// If it is a part of a [CoordinatorModular], it will not have a root path.
  /// And it will not be able to use [routerDelegate] and [routeInformationParser].
  late final bool isRouteModule = () {
    try {
      coordinator;
      return true;
    } on UnimplementedError {
      return false;
    }
  }();

  /// The root (primary) navigation path.
  ///
  /// All coordinators have at least this one path.
  ///
  /// If this coordinator is a part of a [CoordinatorModular], the root path will point to the root path of the [CoordinatorModular].
  StackPath<T> get root;

  /// All navigation paths managed by this coordinator.
  ///
  /// If you add custom paths, make sure to override [paths]
  @override
  @mustCallSuper
  List<StackPath> get paths => isRouteModule ? [] : [root];

  /// Defines the layout structure for this coordinator.
  ///
  /// This method is called during initialization. Override this to register
  /// custom layouts using [Coordinator.defineRouteLayout].
  @override
  void defineLayout() {}

  /// Defines the restorable converters for this coordinator.
  ///
  /// Override this method to register custom restorable converters using
  /// [defineRestorableConverter].
  @override
  void defineConverter() {}

  @mustCallSuper
  void init() {
    defineLayout();
    defineConverter();
  }

  /// The initial route path for this coordinator.
  ///
  /// This path is used to set the initial route when the app is launched.
  final Uri? initialRoutePath;

  /// Returns the current URI based on the active route.
  Uri get currentUri => activePath.activeRoute?.identifier ?? Uri.parse('/');

  /// Returns the deepest active [RouteLayout] in the navigation hierarchy.
  ///
  /// This traverses through nested layouts to find the most deeply nested
  /// layout that is currently active. Returns `null` if the root layout is active.
  @protected
  RouteLayoutParent? get activeLayoutParent {
    T? current = root.activeRoute;
    if (current == null || current is! RouteLayoutParent) return null;

    RouteLayoutParent? deepestRoutePath = current as RouteLayoutParent;

    // Traverse through nested layouts to find the deepest one
    while (current is RouteLayoutParent) {
      deepestRoutePath = current as RouteLayoutParent;
      final path = deepestRoutePath.resolvePath(this);
      current = path.activeRoute as T?;

      // If the next route is not a layout, we've found the deepest layout
      if (current is! RouteLayoutParent) break;
    }

    return deepestRoutePath;
  }

  /// Returns all active [RouteLayout] instances in the navigation hierarchy.
  ///
  /// This traverses through the active route to collect all layouts from root
  /// to the deepest layout. Returns an empty list if no layouts are active.
  @protected
  List<RouteLayoutParent> get activeLayoutParentList {
    List<RouteLayoutParent> layouts = [];
    T? current = root.activeRoute;

    // Traverse through the hierarchy and collect all RouteLayout instances
    while (current != null && current is RouteLayoutParent) {
      final routePath = current as RouteLayoutParent;
      layouts.add(routePath);
      final path = routePath.resolvePath(this);
      current = path.activeRoute as T?;
    }

    return layouts;
  }

  /// Returns the currently active [StackPath].
  ///
  /// This is the path that contains the currently active route.
  StackPath<T> get activePath =>
      (activePaths.lastOrNull ?? root) as StackPath<T>;

  List<StackPath> get activePaths {
    List<StackPath> pathSegment = [root];
    StackPath path = root;
    T? current = root.stack.lastOrNull;
    if (current == null) return pathSegment;

    while (current is RouteLayoutParent) {
      final layout = current as RouteLayoutParent;
      path = layout.resolvePath(this);
      pathSegment.add(path);
      current = path.activeRoute as T?;
    }

    return pathSegment;
  }

  /// Parses a [Uri] into a route object.
  ///
  /// Required override - this is how deep links and web URLs become routes.
  @override
  FutureOr<T?> parseRouteFromUri(Uri uri);

  /// Handles deep link navigation by parsing URI and calling [recover].
  Future<void> recoverRouteFromUri(Uri uri) async {
    final route = await parseRouteFromUri(uri);
    if (route == null) {
      throw StateError(
        'If you want to use coordinator deeplink feature, you must return route from [parseRouteFromUri]',
      );
    }
    return recover(route);
  }

  /// Ensures the layout hierarchy is properly activated for navigation.
  Future<void> _prepareParentLayoutList(
    RouteLayoutParent layout, {
    _ResolveLayoutStrategy strategy = _ResolveLayoutStrategy.override,
  }) async {
    RouteLayoutParent? current = layout;
    List<RouteLayoutParent> parentLayoutList = [];
    List<StackPath> parentLayoutPathList = [];
    while (current != null) {
      parentLayoutList.add(current);
      parentLayoutPathList.add(current.resolvePath(this));
      current = current.resolveParentLayout(this);
    }
    parentLayoutPathList.add(root);

    for (var i = parentLayoutPathList.length - 1; i >= 1; i--) {
      final grandParentLayout = parentLayoutPathList[i];
      final parentLayout = parentLayoutList[i - 1];
      switch (strategy) {
        case _ResolveLayoutStrategy.pushToTop
            when grandParentLayout is StackMutatable:
          grandParentLayout.pushOrMoveToTop(parentLayout);
        // Only [replace] overrides, and it lands on a single history entry.
        // These activations are not awaited, so if they committed as ordinary
        // navigation they would overwrite the replacement intent after the
        // fact — the layouts a replace passes through must be marked too.
        case _ResolveLayoutStrategy.override
            when grandParentLayout is StackMutatable:
          grandParentLayout.activateReplacing(parentLayout);
        default:
          grandParentLayout.activateRoute(parentLayout);
      }
    }
  }

  /// Recovers navigation state from a route, respecting [RouteDeepLink] strategy.
  ///
  /// [navigate]/[push]/[replace] are intentionally not awaited: their futures
  /// complete when the route is later popped (via [StackMutatable.push]), so
  /// awaiting them would hang callers such as [recoverRouteFromUri].
  Future<void> recover(T route) async {
    T? target = await RouteRedirect.resolve(route, this);
    if (target == null) return;

    if (target is RouteDeepLink) {
      switch (target.deeplinkStrategy) {
        case DeeplinkStrategy.navigate:
          navigate(target);
        case DeeplinkStrategy.push:
          push(target);
        case DeeplinkStrategy.replace:
          replace(target);
        case DeeplinkStrategy.custom:
          await target.deeplinkHandler(this, target.identifier);
      }
    } else {
      replace(target);
    }
  }

  /// Navigates to a route with smart history handling.
  ///
  /// If route exists in stack, pops back to it. Otherwise pushes new route.
  /// Used for browser back/forward navigation.
  Future<void> navigate(T route) async {
    final target = await RouteRedirect.resolve(route, this);
    if (target == null) return;

    replacesHistoryEntry = false;

    final parentLayout = target.resolveParentLayout(this);
    if (parentLayout != null) {
      await _prepareParentLayoutList(
        parentLayout,
        strategy: _ResolveLayoutStrategy.pushToTop,
      );
    }

    final parentPath = parentLayout?.resolvePath(this) ?? root;

    assert(
      parentPath is StackNavigatable,
      UnimplementedError(
        'ZenRouter: parentPath (${parentPath.pathKey.key}) does not implement '
        'StackNavigatable. The navigate() call for route $route will have no '
        'effect on the navigation stack or browser history.',
      ),
    );

    if (parentPath case StackNavigatable parentPath) {
      await parentPath.navigate(target);
    }
  }

  /// Clears all paths and sets a single route as the new state.
  Future<void> replace(T route) async {
    T? target = await RouteRedirect.resolve(route, this);
    if (target == null) return;

    // Declare the intent up front. Not every commit a replace performs marks
    // the flag — an IndexedStackPath tab switch notifies without one — so
    // relying on the last commit to set it would leave it unset.
    replacesHistoryEntry = true;

    for (final path in paths) path.reset();

    final parentLayout = target.resolveParentLayout(this);
    if (parentLayout != null) {
      await _prepareParentLayoutList(
        parentLayout,
        strategy: _ResolveLayoutStrategy.override,
      );
    }

    final parentPath = parentLayout?.resolvePath(this) ?? root;
    // A replace lands on the same conceptual history slot: the stack it
    // replaces is gone, so leaving it reachable through the browser's back
    // button would resurrect a screen the app no longer holds.
    if (parentPath case StackMutatable path) {
      await path.activateReplacing(target);
    } else {
      await parentPath.activateRoute(target);
    }
  }

  /// Adds a route to the navigation stack.
  ///
  /// Resolves redirects, ensures layout hierarchy is active, then pushes to path.
  /// Returns a future that completes when the route is popped with a result.
  Future<R?> push<R extends Object>(T route) async {
    T? target = await RouteRedirect.resolve(route, this);
    if (target == null) return null;

    // Forward navigation earns its own history entry. Stated here because a
    // push can commit without any path marking the flag — the layout is
    // already on top and the tab switch does not mark — which would otherwise
    // let a previous replace's intent carry over.
    replacesHistoryEntry = false;

    final parentLayout = target.resolveParentLayout(this);
    if (parentLayout != null) {
      await _prepareParentLayoutList(
        parentLayout,
        strategy: _ResolveLayoutStrategy.pushToTop,
      );
    }

    final parentPath = parentLayout?.resolvePath(this) ?? root;
    switch (parentPath) {
      case StackMutatable():
        return parentPath.push(target);
      default:
        parentPath.activateRoute(target);
        return null;
    }
  }

  /// Pushes a route to the top, or moves it to top if already in stack.
  ///
  /// Useful for tab navigation to switch without duplicating entries.
  void pushOrMoveToTop(T route) async {
    final target = await RouteRedirect.resolve(route, this);
    if (target == null) return;

    replacesHistoryEntry = false;

    final parentLayout = target.resolveParentLayout(this);
    if (parentLayout != null) {
      await _prepareParentLayoutList(
        parentLayout,
        strategy: _ResolveLayoutStrategy.pushToTop,
      );
    }

    final parentPath = parentLayout?.resolvePath(this) ?? root;

    switch (parentPath) {
      case StackMutatable():
        parentPath.pushOrMoveToTop(target);
      default:
        parentPath.activateRoute(target);
    }
  }

  /// Replaces the current route with a new one.
  ///
  /// Pops the current route (respecting guards) then pushes the new route.
  Future<R?> pushReplacement<R extends Object, RO extends Object>(
    T route, {
    RO? result,
  }) async {
    final target = await RouteRedirect.resolve(route, this);
    if (target == null) return null;

    final parentLayout = target.resolveParentLayout(this);
    final parentPath = parentLayout?.resolvePath(this) ?? root;

    final currentPath = this.activePath;
    final currentRoute = currentPath.activeRoute;
    if (currentPath case StackMutatable activePath
        when currentRoute != null && activePath != parentPath) {
      if (activePath.stack.length == 1) {
        currentRoute.completeOnResult(result, this);
        currentRoute.onDiscard();
        activePath.reset();
      } else {
        final popped = await activePath.pop(result);
        if (popped == null || !popped) return null;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        await currentRoute.onResult.future;
      }
    }

    if (parentLayout != null) {
      await _prepareParentLayoutList(
        parentLayout,
        strategy: _ResolveLayoutStrategy.pushToTop,
      );
    }

    if (parentPath case StackMutatable parentPath) {
      return parentPath.pushReplacement(target, result: result);
    }

    return null;
  }

  /// Pops from the nearest eligible path with at least two entries.
  ///
  /// Only the deepest mutatable path is popped. Unlike the previous
  /// multi-path behavior, nested shells are not popped together with
  /// their child stacks in a single call.
  Future<void> pop([Object? result]) async {
    final dynamicPaths = activePaths.whereType<StackMutatable>().toList();

    for (var i = dynamicPaths.length - 1; i >= 0; i--) {
      final path = dynamicPaths[i];
      if (path.stack.length >= 2) {
        await path.pop(result);
        return;
      }
    }
  }

  /// Attempts to pop from the nearest eligible path.
  ///
  /// Returns true if pop succeeded, false if blocked by guard, null if no path eligible.
  Future<bool?> tryPop([Object? result]) async {
    final mutatablePaths = activePaths.whereType<StackMutatable>().toList();

    for (var i = mutatablePaths.length - 1; i >= 0; i--) {
      final path = mutatablePaths[i];
      if (path.stack.length >= 2) {
        return await path.pop(result);
      }
    }

    return null;
  }

  /// Triggers a rebuild of the coordinator.
  void markNeedRebuild() => notifyListeners();

  /// Registers a constructor for a layout parent.
  void defineLayoutParentConstructor(
    Object layoutKey,
    RouteLayoutParentConstructor constructor,
  );

  /// Creates a layout parent instance from registered constructor.
  RouteLayoutParent? createLayoutParent(Object layoutKey);
}
