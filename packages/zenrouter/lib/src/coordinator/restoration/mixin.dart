import 'package:zenrouter/zenrouter.dart';

/// {@template zenrouter.CoordinatorRestoration}
/// Mixins for coordinating route state restoration.
///
/// [CoordinatorRestoration] - Abstract mixin defining the interface for
/// encoding/decoding layout restoration keys.
///
/// ## Role in Navigation Flow
///
/// [CoordinatorRestoration] enables state persistence across app restarts:
/// 1. Encodes layout keys for restoration when layouts are defined
/// 2. Decodes layout keys when restoring navigation state
/// 3. Generates restoration IDs for routes based on their path hierarchy
///
/// When restoration is enabled:
/// - [encodeLayoutKey] is called when layouts are registered
/// - [decodeLayoutKey] is called during restoration to recreate layouts
/// - [resolveRouteId] generates unique IDs for each route's state
/// {@endtemplate}
mixin CoordinatorRestoration<T extends RouteUnique> on CoordinatorCore<T> {
  final _layoutKeyTable = <String, Object>{};
  late final layoutKeyTable = isRouteModule
      ? (coordinator as CoordinatorRestoration)._layoutKeyTable
      : _layoutKeyTable;
  final Map<String, RestoratableConverterConstructor> _converterTable = {};
  late final converterTable = isRouteModule
      ? (coordinator as CoordinatorRestoration)._converterTable
      : _converterTable;

  @override
  void dispose() {
    _layoutKeyTable.clear();
    _converterTable.clear();
    super.dispose();
  }

  /// {@template zenrouter.CoordinatorRestoration.decodeLayoutKey}
  /// Decodes and returns the stored layout key for the given [key].
  /// {@endtemplate}
  Object decodeLayoutKey(String key) {
    final value = layoutKeyTable[key];
    if (value == null) {
      throw UnimplementedError(
        'The [$key] layout is not defined. You must define it using [Coordinator.defineLayoutParent] or via the [bindLayout] method in the corresponding [StackPath].',
      );
    }
    return value;
  }

  /// {@template zenrouter.CoordinatorRestoration.encodeLayoutKey}
  /// Encodes the layout key to be restored later.
  /// {@endtemplate}
  void encodeLayoutKey(Object value) =>
      layoutKeyTable[value.toString()] = value;

  /// The restoration ID for the root path.
  ///
  /// This ID is used to restore the root path when the app is re-launched.
  String get rootRestorationId => root.debugLabel ?? 'root';

  /// The restoration ID for [route], or `null` if it cannot have one.
  ///
  /// A route's id spells out the paths it sits under, so every one of them must
  /// be labelled. A path registered on a coordinator always is, but the widgets
  /// can be used on their own with a path that is not — and a renderer asking
  /// on a route's behalf should not turn that into a crash. Restoration is
  /// simply off for such a subtree, which is where it was before it asked.
  String? tryResolveRouteId(covariant T route) =>
      _resolveRouteId(route, orNull: true);

  /// Resolves the restoration ID for a given route.
  ///
  /// This ID is used to restore the route when the app is re-launched.
  String resolveRouteId(covariant T route) => _resolveRouteId(route)!;

  /// Spells out the paths [route] sits under, innermost first.
  ///
  /// The two public forms differ only in what an unlabelled path means, so they
  /// share the walk: doing it twice cost twice the work for the renderer, which
  /// asks through the nullable one.
  String? _resolveRouteId(T route, {bool orNull = false}) {
    final labels = <String>[];

    // A route with no layout has no chain to walk, and reading the active list
    // below walks the whole hierarchy — so it is not read at all for the routes
    // that would get nothing out of it.
    if (route.parentLayoutKey != null) {
      // Read once for the rest — every read of it walks the hierarchy.
      // ignore: invalid_use_of_protected_member
      final actives = activeLayoutParentList;
      RouteLayout? layout = route.resolveParentLayout(
        this,
        activeLayouts: actives,
      );
      while (layout != null) {
        final label = layout.resolvePath(this).debugLabel;
        if (label == null) {
          // A path registered on a coordinator always has a label, but the
          // widgets can be used on their own with one that does not. A renderer
          // asking on a route's behalf gets `null` — restoration is simply off
          // for that subtree — while an app asking directly still hears about it.
          if (orNull) return null;
          assert(
            false,
            '[StackPath] must have an unique label in order to use with Coordinator restorable',
          );
          return null;
        }
        labels.add(label);
        layout = layout.resolveParentLayout(this, activeLayouts: actives);
      }
    }

    final routeRestorationId = _routeIdPart(route);

    return '${rootRestorationId}_${labels.join('_')}_'
        '${_disambiguate(route, routeRestorationId)}';
  }

  static String? _routeIdPart(RouteTarget route) => switch (route) {
    RouteRestorable() => route.restorationId,
    RouteUri() => route.identifier.toString(),
    _ => null,
  };

  /// [id] made distinct from the entries below [route] on its own path.
  ///
  /// A stack may hold the same route twice — `[/edit, /settings, /edit]` is an
  /// ordinary stack, and page keys have been identity-based since 3.0.0 for
  /// exactly that reason. Their ids are not: both entries asked their navigator
  /// for one restoration bucket, which is an error, and the app died on the
  /// frame that serialised.
  ///
  /// Only a repeat is renamed, so an id that was never ambiguous is the string
  /// it always was — state saved under it still comes back. Entries on the same
  /// path share the layout prefix, so comparing the route part settles it.
  String _disambiguate(T route, String? id) {
    final stack = route.stackPath?.stack;
    if (stack == null || id == null) return '$id';

    var seen = 0;
    var found = false;
    for (final other in stack) {
      if (identical(other, route)) {
        found = true;
        break;
      }
      if (_routeIdPart(other) == id) seen++;
    }
    // Not on the path it names: an id asked for on a route's behalf before it
    // is pushed, where there is no position to count from.
    if (!found || seen == 0) return id;
    return '$id#$seen';
  }

  void defineRestorableConverter(
    String key,
    RestoratableConverterConstructor<T> constructor,
  ) => converterTable[key] = constructor;

  RestorableConverter? getRestorableConverter(String key) =>
      converterTable[key]?.call() ?? RestorableConverter.buildConverter(key);
}
