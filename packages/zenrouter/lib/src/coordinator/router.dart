import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:zenrouter/zenrouter.dart';

/// {@template zenrouter.CoordinatorRouteParser}
/// Parses [RouteInformation] to and from [Uri].
///
/// This is used by Flutter's Router widget to handle URL changes.
///
/// ## Role in Navigation Flow
///
/// [CoordinatorRouteParser] bridges URL changes and the navigation system:
/// 1. Flutter's Router calls [parseRouteInformation] when URL changes
/// 2. The parsed URI is passed to [CoordinatorRouterDelegate.setNewRoutePath]
/// 3. The coordinator navigates to the appropriate route
///
/// This class is used internally by [MaterialApp.router] configuration.
/// {@endtemplate}
class CoordinatorRouteParser extends RouteInformationParser<Uri> {
  const CoordinatorRouteParser({required this.coordinator});

  final Coordinator coordinator;

  /// Converts [RouteInformation] to a [Uri] configuration.
  @override
  Future<Uri> parseRouteInformation(RouteInformation routeInformation) async {
    return routeInformation.uri;
  }

  /// Converts a [Uri] configuration back to [RouteInformation].
  @override
  RouteInformation? restoreRouteInformation(Uri configuration) {
    return RouteInformation(uri: configuration);
  }
}

/// {@template zenrouter.CoordinatorRouterDelegate}
/// Router delegate that connects the [Coordinator] to Flutter's Router.
///
/// Manages the navigator stack and handles system navigation events.
///
/// ## Role in Navigation Flow
///
/// [CoordinatorRouterDelegate] acts as the bridge between Flutter and ZenRouter:
/// 1. Receives route changes via [setNewRoutePath] from Flutter's Router
/// 2. Delegates navigation to the [Coordinator] for processing
/// 3. Builds the navigation widget tree via [coordinator.layoutBuilder]
/// 4. Handles system back button via [popRoute]
///
/// This delegate is automatically created by [Coordinator] and used in
/// [MaterialApp.router] configuration.
/// {@endtemplate}
class CoordinatorRouterDelegate extends RouterDelegate<Uri>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<Uri> {
  CoordinatorRouterDelegate({required this.coordinator}) {
    coordinator.addListener(notifyListeners);
  }

  final Coordinator coordinator;

  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  Uri? get currentConfiguration => coordinator.currentUri;

  String get coordinatorRestorationId =>
      '_${coordinator.rootRestorationId}_coordinator_restorable';

  @override
  Widget build(BuildContext context) {
    assert(_debugCheckRouteInformationProvider(context));
    return CoordinatorRestorable(
      coordinator: coordinator,
      restorationId: coordinatorRestorationId,
      child: coordinator.layoutBuilder(context),
    );
  }

  /// Warns when the [Router] was handed a delegate and a parser but not the
  /// coordinator's [Coordinator.routeInformationProvider].
  ///
  /// Flutter then builds its own provider, and the coordinator's — which is
  /// what lets `replace` and `pushReplacement` overwrite the browser history
  /// entry instead of adding one — is never consulted. The symptom is
  /// web-only and silent: the back button walks into screens the app has
  /// already discarded, such as the login page you just signed in from.
  bool _debugWarnedAboutProvider = false;

  bool _debugCheckRouteInformationProvider(BuildContext context) {
    // Only the web has a history stack to get wrong; elsewhere the platform
    // back button unwinds the Navigator and the provider is irrelevant.
    if (!kIsWeb) return true;
    if (_debugWarnedAboutProvider) return true;

    // Ask the provider rather than the Router: `MaterialApp.router` builds a
    // `Router<Object>`, so looking it up by our configuration type fails. A
    // Router subscribes to its provider in `initState`, before this build, so
    // an unsubscribed provider means ours was never handed over.
    final provider = coordinator.routeInformationProvider;
    if (provider is! CoordinatorRouteInformationProvider) return true;
    if (provider.isAttached) return true;

    _debugWarnedAboutProvider = true;
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: FlutterError.fromParts([
          ErrorSummary(
            'The Router is not using the coordinator\'s '
            'routeInformationProvider.',
          ),
          ErrorDescription(
            'Browser history then treats every navigation as a new entry, so '
            '`replace` and `pushReplacement` leave discarded screens reachable '
            'through the back button.',
          ),
          ErrorHint(
            'Pass the coordinator as a whole:\n'
            '  MaterialApp.router(routerConfig: coordinator)\n'
            'or supply the provider alongside the delegate:\n'
            '  MaterialApp.router(\n'
            '    routerDelegate: coordinator.routerDelegate,\n'
            '    routeInformationParser: coordinator.routeInformationParser,\n'
            '    routeInformationProvider: coordinator.routeInformationProvider,\n'
            '  )',
          ),
        ]),
        library: 'zenrouter',
      ),
    );
    return true;
  }

  /// Handles browser navigation events (back/forward buttons, URL changes).
  ///
  /// This method is called by Flutter's Router when the browser URL changes,
  /// either from user action (back/forward buttons) or programmatic navigation.
  ///
  /// **Subsequent Navigation:**
  /// For browser back/forward buttons:
  ///
  /// - **NavigationPath**: If the route exists in the stack, pops until
  ///   reaching that route. If not found, pushes it as a new route.
  ///   - Guards are consulted during popping
  ///   - If any guard blocks navigation, the URL is restored via [notifyListeners]
  ///   - Uses a while loop to handle dynamic stack changes during iteration
  ///
  /// - **IndexedStackPath**: Activates the route (switches tab) after ensuring
  ///   parent layouts are properly resolved.
  ///
  /// **URL Synchronization:**
  /// When navigation fails (guard blocks or layout resolution fails),
  /// [notifyListeners] is called to restore the browser URL to match
  /// the current app state, keeping URL and navigation state in sync.
  ///
  /// **Invariants:**
  /// - Routes cannot exist in multiple paths (each route has one path)
  /// - Route layouts are determined at creation and don't change
  /// - Path types (NavigationPath vs IndexedStackPath) are static
  @override
  Future<void> setNewRoutePath(Uri configuration) async {
    final route = await coordinator.parseRouteFromUri(configuration);
    assert(
      () {
        try {
          final _ = coordinator.coordinator;
          return true;
        } on UnimplementedError catch (err) {
          if (err.message?.contains('This coordinator is standalone') == true) {
            return route != null;
          }
          return true;
        }
      }(),
      'If you want to use coordinator as [RouterConfig], you must return route from [parseRouteFromUri]',
    );

    if (route case RouteDeepLink(:final deeplinkStrategy)) {
      final recovery = coordinator.recover(route!);

      // The router reports `currentConfiguration` the moment this returns, so
      // returning early — while the app is still on the previous URI — writes a
      // history entry for a screen the user never saw. The browser then has two
      // entries to walk back through for every one the user made.
      //
      // Only [DeeplinkStrategy.stack] can be waited for: it settles once the
      // stack has been established. The others settle when the route is later
      // *popped* — `navigate`/`push`/`replace` are fired unawaited inside
      // [CoordinatorCore.recover] for exactly that reason, and a custom handler
      // is app-defined and free to await one of them.
      if (deeplinkStrategy == DeeplinkStrategy.stack) await recovery;
      return;
    }

    assert(
      route != null,
      'You must to provide a parse route for $configuration in [parseRouteFromUri] to use deeplink to it',
    );
    // Not awaited: navigate → push future completes when the route is popped.
    coordinator.navigate(route!);
  }

  /// The platform's starting URI, resolved once at launch.
  ///
  /// It replaces rather than pushes: working out which route the launch URI
  /// means is the app settling on where it already is, not the user going
  /// somewhere. Reported as a new entry, a freshly loaded page would start with
  /// two — the URI the browser opened and the route it resolved to — so leaving
  /// the app would take two back presses.
  ///
  /// A deep link goes through [CoordinatorCore.recover], which owns its own
  /// history semantics per strategy, so it is left alone.
  @override
  Future<void> setInitialRoutePath(Uri configuration) async {
    final route = await coordinator.parseRouteFromUri(configuration);
    if (route == null || route is RouteDeepLink) {
      return setNewRoutePath(configuration);
    }
    coordinator.replace(route);
  }

  /// Dont need to handle restored route since it handled in [CoordinatorRestorable]
  @override
  Future<void> setRestoredRoutePath(Uri configuration) async {}

  @override
  Future<bool> popRoute() async {
    final result = await coordinator.tryPop();
    return result ?? false;
  }

  @override
  void dispose() {
    coordinator.removeListener(notifyListeners);
    super.dispose();
  }
}
