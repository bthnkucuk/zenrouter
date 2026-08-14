import 'dart:async';

import 'package:zenrouter_core/src/coordinator/base.dart';
import 'package:zenrouter_core/src/mixin/uri.dart';

/// Strategy that determines how [CoordinatorCore] handles deep links.
///
/// When a route with [RouteDeepLink] is navigated to via URL/deep link,
/// the coordinator uses this strategy to decide the navigation behavior.
enum DeeplinkStrategy {
  /// Replaces the current navigation stack with the deep linked route.
  /// This is the default behavior for most deep links.
  replace,

  /// Navigates to the route, handling browser history properly.
  /// If the route exists in the stack, it pops back to it instead of pushing.
  /// Suitable for web navigation where back/forward buttons should work correctly.
  navigate,

  /// Pushes the route onto the existing navigation stack.
  /// The back button will return to the previous route.
  push,

  /// Establishes the whole stack the route says it sits on, via
  /// [RouteDeepLink.deeplinkStack].
  ///
  /// A URI usually implies more than the screen it points at: `/products/42` is
  /// a detail sitting on a list. The other strategies can only place that one
  /// screen, so arriving cold leaves nothing underneath and the back button
  /// leaves the app.
  stack,

  /// Uses a custom handler defined in [RouteDeepLink.deeplinkHandler].
  /// Allows complete control over how the deep link is processed.
  custom,
}

/// Mixin for routes that specify deep link handling behavior.
///
/// When routes are navigated to via URLs (web deep links or app links),
/// the coordinator uses this mixin to determine how to handle the navigation.
/// Routes without this mixin default to [DeeplinkStrategy.replace].
/// Mixin for routes that specify deep link handling behavior.
///
/// When routes are navigated to via URLs (web deep links or app links),
/// the coordinator uses this mixin to determine how to handle the navigation.
/// Routes without this mixin default to [DeeplinkStrategy.replace].
mixin RouteDeepLink on RouteUri {
  /// The strategy to use when handling this deep link.
  ///
  /// Determines how the coordinator modifies the navigation stack when
  /// this route is reached via a deep link.
  DeeplinkStrategy get deeplinkStrategy;

  // coverage:ignore-start
  /// The stack this route sits on, bottom entry first, ending with the route
  /// itself.
  ///
  /// Called when [deeplinkStrategy] is [DeeplinkStrategy.stack]. The route was
  /// already built from the URI, so it knows its own parameters; [uri] is there
  /// for the cases where what sits underneath depends on more than the route
  /// itself.
  ///
  /// ```dart
  /// @override
  /// DeeplinkStrategy get deeplinkStrategy => DeeplinkStrategy.stack;
  ///
  /// @override
  /// List<RouteUri> deeplinkStack(Uri uri) => [ProductList(), this];
  /// ```
  List<RouteUri> deeplinkStack(Uri uri) => [this];

  /// Custom handler called when [deeplinkStrategy] is [DeeplinkStrategy.custom].
  ///
  /// This allows full control over deep link processing, including accessing
  /// the URI, coordinating with app state, or performing custom transitions.
  FutureOr<void> deeplinkHandler(
    covariant CoordinatorCore coordinator,
    Uri uri,
  ) => null;
  // coverage:ignore-end
}
