import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zenrouter/src/coordinator/base.dart';
import 'package:zenrouter/src/coordinator/observer.dart';
import 'package:zenrouter/src/internal/type.dart';
import 'package:zenrouter/src/internal/reactive.dart';
import 'package:zenrouter/src/mixin/unique.dart';
import 'package:zenrouter/src/path/indexed.dart';
import 'package:zenrouter/src/path/navigation.dart';
import 'package:zenrouter/src/path/restoration.dart';
import 'package:zenrouter/src/path/transition.dart';
import 'package:zenrouter/src/path/transition_delegate.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

/// A widget that renders a stack of pages based on a [NavigationPath].
///
/// This is the core widget for imperative navigation. It listens to the [path]
/// and updates the [Navigator] with the corresponding pages.
///
/// ## Role in Navigation Flow
///
/// [NavigationStack] is the visual representation of a [NavigationPath]:
/// 1. Listens to path changes via path listeners
/// 2. Uses Myers diff algorithm to calculate route changes
/// 3. Builds [Page] objects via the [resolver] callback
/// 4. Updates Flutter's Navigator with the page stack
///
/// The widget handles:
/// - Page creation and disposal
/// - Guard execution on pop attempts
/// - Route result completion
/// - State restoration
class NavigationStack<T extends RouteTarget> extends StatefulWidget {
  const NavigationStack({
    super.key,
    required this.path,
    required this.resolver,
    this.defaultRoute,
    this.observers = const [],
    this.coordinator,
    this.navigatorKey,
    this.parseRouteFromUri,
    this.restorationId,
  }) : assert(
         restorationId == null ||
             (coordinator != null || parseRouteFromUri != null),
         'Please provide either coordinator or parseRouteFromUri for restoration working',
       );

  /// Creates a declarative navigation stack.
  ///
  /// This factory method creates a [DeclarativeNavigationStack] which manages
  /// the stack based on a list of routes.
  static DeclarativeNavigationStack<T> declarative<T extends RouteTarget>({
    required List<T> routes,
    required StackTransitionResolver<T> resolver,
    GlobalKey<NavigatorState>? navigatorKey,
    String? debugLabel,
    String? restorationId,
    T Function(Uri uri)? parseRouteFromUri,
  }) {
    return DeclarativeNavigationStack(
      routes: routes,
      navigatorKey: navigatorKey,
      debugLabel: debugLabel,
      resolver: resolver,
      restorationId: restorationId,
      parseRouteFromUri: parseRouteFromUri,
    );
  }

  /// Optional key for accessing the navigator state.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// The associated coordinator
  final Coordinator? coordinator;

  final String? restorationId;

  final T Function(Uri uri)? parseRouteFromUri;

  /// A list of observers for this navigator.
  final List<NavigatorObserver> observers;

  /// The navigation path to render.
  final NavigationPath<T> path;

  /// Callback that converts routes to destinations.
  final StackTransitionResolver<T> resolver;

  /// Optional route to push when the stack initializes.
  final T? defaultRoute;

  @override
  State<NavigationStack<T>> createState() => _NavigationStackState<T>();
}

class _NavigationStackState<T extends RouteTarget>
    extends State<NavigationStack<T>>
    with RestorationMixin {
  List<Page> _pages = [];
  List<T> _previousRoutes = [];

  List<NavigatorObserver> _observers = [];

  NavigationPathRestorable<T>? _restorable;

  /// Observers this navigator owns, built once and kept.
  List<NavigatorObserver> _builtObservers = const [];

  void _updateObservers() {
    final coordinator = widget.coordinator;
    if (coordinator is! CoordinatorNavigatorObserver) {
      _observers = widget.observers;
      return;
    }

    // Built once per navigator and reused. Calling the builder again would
    // hand this navigator fresh instances, losing whatever the previous ones
    // had accumulated — and a navigator may not share instances with the
    // sibling navigators a coordinator runs alongside it.
    if (_builtObservers.isEmpty) {
      _builtObservers = coordinator.observersBuilder();
    }

    _observers = [
      ..._builtObservers,
      // ignore: deprecated_member_use_from_same_package
      ...coordinator.observers,
      ...widget.observers,
    ];
  }

  @override
  void initState() {
    super.initState();
    if (widget.defaultRoute != null) {
      widget.path.pushOrMoveToTop(widget.defaultRoute!);
    }
    widget.path.addListener(_updatePages);
    widget.path.addListener(_updateRestorable);
    _updatePages();
    _updateObservers();
  }

  @override
  void dispose() {
    widget.path.removeListener(_updatePages);
    widget.path.removeListener(_updateRestorable);
    _restorable?.dispose();
    super.dispose();
  }

  Page _buildPage(T route) {
    /// Set path to route
    // ignore: invalid_use_of_protected_member
    route.bindStackPath(widget.path);
    final destination = widget.resolver(route);
    final RouteGuard? guard = switch (route) {
      final RouteGuard routeGuard => routeGuard,
      _ => destination.guard,
    };

    return destination.pageBuilder(
      context,
      ObjectKey(route),
      _buildPopScope(route: route, guard: guard, destination: destination),
    );
  }

  Widget _buildPopScope({
    required T route,
    required RouteGuard? guard,
    required StackTransition<T> destination,
  }) {
    Widget buildScope(bool canPop) {
      return PopScope(
        canPop: canPop,
        onPopInvokedWithResult: (didPop, result) async {
          // ignore: invalid_use_of_protected_member
          if (route.stackPath == null) route.bindStackPath(widget.path);
          if (!(kIsWeb || kIsWasm)) {
            assert(
              identical(route.stackPath, widget.path),
              'Route must be from the same path',
            );
          }

          switch (didPop) {
            case true when result != null:
              route.completeOnResult(result, widget.coordinator);
              route.onDidPop(result, widget.coordinator);
            case true:
              result = route.resultValue;
              route.completeOnResult(
                result,
                widget.coordinator,

                /// Fail silently if it's a force pop from the platform.
                route.isPopByPath == false,
              );
              route.onDidPop(result, widget.coordinator);
            case false when route is RouteGuard:
              widget.path.pop();
            case false when destination.guard != null:
              final popped = switch (widget.coordinator) {
                null => await destination.guard?.popGuard(),
                // Never happen
                // coverage:ignore-start
                final coordinator => await destination.guard?.popGuardWith(
                  coordinator,
                ),
              };
              if (popped == true) widget.path.pop();
            case false:
            // coverage:ignore-end
          }
        },
        child: destination.builder(context),
      );
    }

    if (guard == null) return buildScope(true);

    final coordinator = widget.coordinator;
    final canPopListenable = switch (coordinator) {
      null => guard.canPopListenable,
      final c => guard.canPopListenableWith(c),
    };
    bool resolveCanPop() => switch (coordinator) {
      null => guard.canPop,
      final c => guard.canPopWith(c),
    };

    if (canPopListenable == null) return buildScope(resolveCanPop());

    return ListenableBuilder(
      listenable: canPopListenable.toFlutterListenable(),
      builder: (context, _) => buildScope(resolveCanPop()),
    );
  }

  void _updatePages() {
    final currentRoutes = widget.path.stack;

    // Calculate diff between previous and current routes
    final diffOps = myersDiff(_previousRoutes, currentRoutes);

    // Build new pages list using diff operations
    final newPages = <Page>[];
    for (final op in diffOps) {
      switch (op) {
        case Keep<T>(:final oldIndex, :final newIndex):
          // A route that stays on the stack can still have taken on new data:
          // `navigate` and `pushOrMoveToTop` hand the existing route the
          // incoming one through [RouteTarget.onUpdate]. Reusing its Page then
          // shows stale content, because the same widget instance makes
          // Flutter short-circuit the subtree.
          //
          // Only such routes are rebuilt; the rest keep their Page, so the
          // cost stays proportional to what actually changed. Page identity is
          // unaffected either way — the key is the route instance — so the
          // Navigator refreshes the page instead of replacing it and its
          // widget state survives.
          final route = currentRoutes[newIndex];
          if (route.needsRefresh) {
            // ignore: invalid_use_of_protected_member
            route.didRefresh();
            newPages.add(_buildPage(route));
          } else {
            newPages.add(_pages[oldIndex]);
          }
        case Insert<T>(:final element):
          // Create new page
          newPages.add(_buildPage(element));
        case Delete<T>():
          // Skip deleted pages
          break;
      }
    }

    _pages = newPages;
    _previousRoutes = List.from(currentRoutes);
    setState(() {});
  }

  void _updateRestorable() {
    if (_restorable == null) return;
    if (listEquals(_restorable!.value, widget.path.stack)) return;
    // Copied: `stack` is a live view, and a restorable that held it would
    // compare equal to itself for ever and stop saving.
    _restorable!.value = List<T>.of(widget.path.stack);
  }

  /// Whether both widgets name the same coordinator.
  ///
  /// Compared by identity rather than by observer list: the observers this
  /// navigator owns were built for it and must survive a rebuild, so the only
  /// thing worth reacting to is the coordinator being swapped out entirely.
  bool coordinatorEquals(Coordinator? a, Coordinator? b) => identical(a, b);

  @override
  void didUpdateWidget(covariant NavigationStack<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      // Both listeners move, or the old path keeps one — and a listener is a
      // bound method, so it holds this State and everything under it. `dispose`
      // would then remove the survivor from the *new* path, where it is not.
      oldWidget.path.removeListener(_updatePages);
      oldWidget.path.removeListener(_updateRestorable);
      widget.path.addListener(_updatePages);
      widget.path.addListener(_updateRestorable);
      // Reset previous routes and rebuild pages for the new path
      _previousRoutes = [];
      _updatePages();
    }
    if (!coordinatorEquals(oldWidget.coordinator, widget.coordinator)) {
      // A different coordinator owns this navigator now, so its observers do
      // not belong to it any more.
      _builtObservers = const [];
      _updateObservers();
    } else if (!listEquals(oldWidget.observers, widget.observers)) {
      _updateObservers();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) return const SizedBox.shrink();
    return Navigator(
      key: widget.navigatorKey,
      pages: _pages,
      observers: _observers,
      // Flutter's default delegate drops a page's exit transition whenever
      // anything is above it — including a dialog the user has just dismissed,
      // which is what every pop guard leaves behind.
      transitionDelegate: const ZenTransitionDelegate(),

      // The Navigator removed a page on its own — an imperative
      // `Navigator.pop`, an interactive swipe back, a predictive back. Flutter
      // requires the pages list to stop including that page, so sync the path.
      //
      // Pages are keyed by route instance, so the key names the exact entry
      // that left; matching by value would pick the wrong one on a stack that
      // repeats a route. Removals we initiated ourselves are declarative and
      // never reach here, and the call is a no-op if the route is already gone.
      onDidRemovePage: (page) {
        final key = page.key;
        if (key is! ObjectKey) return;
        if (key.value case final T route) {
          widget.path.removeIdentical(route, discard: false);
        }
      },
      restorationScopeId: switch (widget.restorationId) {
        null => null,
        final restorationId => '${restorationId}_navigator',
      },
    );
  }

  @override
  String? get restorationId => switch (widget.restorationId) {
    null => null,
    final restorationId => '${restorationId}_stack',
  };

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    /// If the path is managed by Coordinator, it will be restored based on the Coordinator
    if (widget.coordinator != null) return;

    if (widget.parseRouteFromUri != null && _restorable == null) {
      _restorable ??= NavigationPathRestorable(widget.parseRouteFromUri!);
      registerForRestoration(_restorable!, '_path');
    }

    if (initialRestore && _restorable != null) {
      if (_restorable!.value.isNotEmpty == false) return;
      widget.path.restore(_restorable!.value);
    }
  }
}

/// A widget that manages a navigation stack declaratively.
///
/// Instead of pushing and popping, you provide a list of [routes]. The widget
/// calculates the difference between the old and new routes (using Myers diff)
/// and updates the stack accordingly.
///
/// ## Role in Navigation Flow
///
/// [DeclarativeNavigationStack] provides declarative navigation:
/// 1. Receives a list of routes as the source of truth
/// 2. Compares with previous route list using Myers diff
/// 3. Updates the underlying [NavigationPath] accordingly
/// 4. Uses the same [NavigationStack] for rendering
class DeclarativeNavigationStack<T extends RouteTarget> extends StatefulWidget {
  const DeclarativeNavigationStack({
    super.key,
    required this.routes,
    this.navigatorKey,
    this.debugLabel,
    required this.resolver,
    this.restorationId,
    this.parseRouteFromUri,
  });

  /// The list of routes to display.
  final List<T> routes;

  /// Optional key for the navigator.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Optional debug label for the path.
  final String? debugLabel;

  /// Callback to resolve routes to pages.
  final StackTransitionResolver<T> resolver;

  final String? restorationId;

  /// Callback to parse routes from Uri.
  final T Function(Uri uri)? parseRouteFromUri;

  @override
  // ignore: library_private_types_in_public_api
  State<DeclarativeNavigationStack<T>> createState() =>
      _DeclarativeNavigationStackState<T>();
}

class _DeclarativeNavigationStackState<T extends RouteTarget>
    extends State<DeclarativeNavigationStack<T>> {
  late final path = NavigationPath<T>.create(label: widget.debugLabel);
  List<T> _previousRoutes = [];

  @override
  void initState() {
    super.initState();
    _updateStack();
  }

  @override
  void didUpdateWidget(DeclarativeNavigationStack<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.routes != oldWidget.routes) {
      _updateStack();
    }
  }

  void _updateStack() {
    // Calculate diff between previous and current routes
    final diffOps = myersDiff(_previousRoutes, widget.routes);

    // Apply the diff operations to the navigation path
    applyDiff(path, diffOps);

    // Update previous routes for next comparison
    _previousRoutes = List.from(widget.routes);
  }

  @override
  Widget build(BuildContext context) {
    return NavigationStack(
      path: path,
      resolver: widget.resolver,
      navigatorKey: widget.navigatorKey,
      restorationId: widget.restorationId,
      parseRouteFromUri: widget.parseRouteFromUri,
    );
  }
}

/// Widget that builds an [IndexedStack] from an [IndexedStackPath].
/// Ensures that the stack caches pages when rebuilding the widget tree.
///
/// ## Role in Navigation Flow
///
/// [IndexedStackPathBuilder] renders indexed navigation:
/// 1. Receives an [IndexedStackPath] with fixed routes
/// 2. Builds all route widgets once and caches them
/// 3. Uses [IndexedStack] to show only the active route
/// 4. Rebuilds when the active index changes
class IndexedStackPathBuilder<T extends RouteUnique> extends StatefulWidget {
  const IndexedStackPathBuilder({
    super.key,
    required this.path,
    required this.coordinator,
  });

  /// The path that maintains the indexed stack state.
  final IndexedStackPath<T> path;

  /// The coordinator used to resolve and build routes in the stack.
  final Coordinator coordinator;

  @override
  State<IndexedStackPathBuilder<T>> createState() =>
      _IndexedStackPathBuilderState<T>();
}

class _IndexedStackPathBuilderState<T extends RouteUnique>
    extends State<IndexedStackPathBuilder<T>> {
  List<Widget>? _children;

  /// The entries [_children] was built from, so a rebuild can tell a changed
  /// set of tabs from a changed *active* tab.
  List<T> _builtFrom = const [];

  /// Tabs that have never been shown, when the path is lazy. They render as
  /// nothing until they are, and are built exactly once when they are.
  final Set<int> _pending = <int>{};

  /// Wraps a tab in a restoration scope of its own.
  ///
  /// Tabs are siblings in one subtree and, unlike a `NavigationPath`, have no
  /// navigator to namespace them, so without this two tabs holding a widget
  /// with the same `restorationId` — a shared form, say — would ask the same
  /// bucket for their state. The id already spans the layout chain, so it is
  /// unique on its own.
  ///
  /// A null id turns restoration off for that tab, which happens when there is
  /// nothing to key it by (an unlabelled path) or nothing above to restore into
  /// (an app that does not restore at all).
  Widget _tab(T route) {
    // Building is what the refresh asked for, so the mark is spent here — in
    // both the first build and a later one. Leaving it set would have the tab
    // rebuilt again the next time any other tab is updated.
    // ignore: invalid_use_of_protected_member
    route.didRefresh();
    return RestorationScope(
      restorationId: widget.coordinator.tryResolveRouteId(route),
      child: route.build(widget.coordinator, context),
    );
  }

  /// The children, built once and reused.
  ///
  /// Switching tabs must not rebuild anything — an indexed stack exists so
  /// every tab keeps its state — so the cache is kept for as long as the
  /// entries are the same instances. Identity is the trigger, not equality: a
  /// tab route stays the same object across builds, while a different path
  /// brings different objects and must not go on rendering the old ones.
  List<Widget> _childrenFor(List<T> stack, int activeIndex) {
    final cached = _children;
    var reusable = cached != null && _builtFrom.length == stack.length;
    if (reusable) {
      for (var index = 0; index < stack.length; index++) {
        if (identical(_builtFrom[index], stack[index])) continue;
        reusable = false;
        break;
      }
    }

    if (!reusable) {
      _builtFrom = List<T>.of(stack);
      _pending.clear();
      if (widget.path.lazy) {
        for (var index = 0; index < stack.length; index++) {
          if (index != activeIndex) _pending.add(index);
        }
      }
      return _children = [
        for (var index = 0; index < stack.length; index++)
          if (_pending.contains(index))
            const SizedBox.shrink()
          else
            _tab(stack[index]),
      ];
    }

    // Reused, with two exceptions. A tab being shown for the first time takes
    // the place of its placeholder and is kept from then on; and a tab whose
    // route took on new data is built again, or it would go on showing what it
    // was handed before. `IndexedStack` renders whatever widget it is given, so
    // reusing the cached one means the screen ignores the update the route
    // already accepted.
    List<Widget>? next;
    if (_pending.remove(activeIndex)) {
      next = List<Widget>.of(cached!);
      next[activeIndex] = _tab(stack[activeIndex]);
    }
    for (var index = 0; index < stack.length; index++) {
      if (_pending.contains(index) || !stack[index].needsRefresh) continue;
      next ??= List<Widget>.of(cached!);
      next[index] = _tab(stack[index]);
    }
    return _children = next ?? cached!;
  }

  @override
  Widget build(BuildContext context) {
    final activeIndex = widget.path.activeIndex;
    final children = _childrenFor(widget.path.stack, activeIndex);
    return IndexedStack(
      index: activeIndex,
      children: [
        for (var index = 0; index < children.length; index++)
          // Flutter's `IndexedStack` keeps every child ticking, so an animation
          // in a tab the user cannot see rebuilds it on every frame for as long
          // as the app runs.
          if (widget.path.pauseHiddenTabs)
            TickerMode(enabled: index == activeIndex, child: children[index])
          else
            children[index],
      ],
    );
  }
}
