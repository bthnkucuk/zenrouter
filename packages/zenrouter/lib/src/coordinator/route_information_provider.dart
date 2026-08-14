import 'package:flutter/widgets.dart';
import 'package:zenrouter/zenrouter.dart';

/// A [RouteInformationProvider] that derives its initial route from both the
/// platform and a [Coordinator].
///
/// The initial [Uri] is resolved by first parsing the platform dispatcher’s
/// [defaultRouteName]. If that route has no path segments (is effectively
/// empty) and [Coordinator.initialRoutePath] is non-null, the coordinator’s
/// [initialRoutePath] is used instead. When an initial URI is chosen but has
/// an empty path, it is normalized to `/`, and if no usable platform route
/// can be parsed the URI defaults to `/`.
class CoordinatorRouteInformationProvider
    extends PlatformRouteInformationProvider {
  CoordinatorRouteInformationProvider({required Coordinator coordinator})
    : _coordinator = coordinator,
      super(
        initialRouteInformation: RouteInformation(
          uri: resolveInitialUri(
            WidgetsBinding.instance.platformDispatcher.defaultRouteName,
            coordinator.initialRoutePath,
          ),
        ),
      );

  final Coordinator _coordinator;

  Coordinator get coordinator => _coordinator;

  bool _isAttached = false;

  /// Whether a [Router] has subscribed to this provider.
  ///
  /// `false` means the app handed the [Router] a delegate and a parser but not
  /// this provider, so Flutter built its own and the history handling below
  /// never runs.
  bool get isAttached => _isAttached;

  @override
  void addListener(VoidCallback listener) {
    _isAttached = true;
    super.addListener(listener);
  }

  /// Lets a replacement overwrite the browser history entry instead of adding
  /// one, so `replace` and `pushReplacement` do not leave a screen the app has
  /// already discarded reachable through the back button.
  ///
  /// The intent is read here rather than passed in because the mutation is
  /// async: by the time the router reports the new URI — in a post-frame
  /// callback — a synchronous `Router.neglect` around the navigation call has
  /// long since returned.
  @override
  void routerReportsNewRouteInformation(
    RouteInformation routeInformation, {
    RouteInformationReportingType type = RouteInformationReportingType.none,
  }) {
    super.routerReportsNewRouteInformation(
      routeInformation,
      type: _coordinator.replacesHistoryEntry
          ? RouteInformationReportingType.neglect
          : type,
    );
  }

  @visibleForTesting
  static Uri resolveInitialUri(String? platformRouteName, Uri? initialUri) {
    final defaultUri = Uri.tryParse(platformRouteName ?? '');

    // If the platform route name can't be parsed, fall back to the provided
    // initialUri when available; otherwise, use the root route.
    if (defaultUri == null) {
      return initialUri ?? Uri.parse('/');
    }

    if (defaultUri.pathSegments.isEmpty && initialUri != null) {
      return initialUri;
    }

    if (defaultUri.hasEmptyPath) {
      return defaultUri.replace(path: '/');
    }

    return defaultUri;
  }
}
