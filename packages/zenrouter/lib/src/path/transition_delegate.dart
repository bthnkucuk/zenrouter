import 'package:flutter/widgets.dart';

/// Keeps a page's exit transition when the only thing above it never covered
/// it — a dialog the user just dismissed, or one leaving in the same frame.
///
/// Flutter's [DefaultTransitionDelegate] completes an exiting page instead of
/// popping it whenever anything else is above it, and completing is not
/// animated: the screen disappears in one frame rather than sliding away. That
/// rule is right while the thing above is on screen and opaque. It is wrong for
/// the two cases below, which is why this delegate exists — a pop guard
/// produces one of them every single time it is answered.
///
/// Adapted from `DefaultTransitionDelegate.resolve` in Flutter's
/// `widgets/navigator.dart` (BSD-3-Clause), which it matches except for:
///
/// 1. **A pageless route that has already been popped is ignored.** Pageless
///    routes are pushed imperatively rather than through `pages` — anything
///    from `showDialog` or `showModalBottomSheet`. Once dismissed, such a route
///    is on its way out by itself and should not cost the page underneath its
///    transition. Flutter distinguishes the two states already:
///    [RouteTransitionRecord.isWaitingForExitingDecision] is `false` for a route
///    that has been popped.
/// 2. **A page covered only by non-opaque exiting pages still animates.** A
///    `StackTransition.dialog` or `.sheet` leaving at the same moment sits over
///    the page without hiding it, so the page has a transition of its own to
///    play. Two ordinary opaque screens leaving together behave as before: only
///    the top one animates, because the one below is not on screen to animate.
/// 3. **The topmost pageless route still *awaiting* a decision is the one
///    popped**, rather than the last in the list. They differ only when an
///    already-popped route sits above one that is still waiting; the default
///    completes the waiting one, this pops it, so it animates out like any other
///    top route.
class ZenTransitionDelegate<T> extends TransitionDelegate<T> {
  const ZenTransitionDelegate();

  @override
  Iterable<RouteTransitionRecord> resolve({
    required List<RouteTransitionRecord> newPageRouteHistory,
    required Map<RouteTransitionRecord?, RouteTransitionRecord>
    locationToExitingPageRoute,
    required Map<RouteTransitionRecord?, List<RouteTransitionRecord>>
    pageRouteToPagelessRoutes,
  }) {
    final results = <RouteTransitionRecord>[];

    /// Whether another leaving page still hides [record] from view.
    ///
    /// Only an opaque one does. A dialog or a sheet leaving at the same moment
    /// sits over the page without covering it, so the page has a transition of
    /// its own to play and should not be dropped to a bare removal.
    bool isCoveredByExiting(RouteTransitionRecord record) {
      final above = locationToExitingPageRoute[record];
      if (above == null) return false;
      final route = above.route;
      if (route is TransitionRoute && !route.opaque) {
        return isCoveredByExiting(above);
      }
      return true;
    }

    void handleExitingRoute(RouteTransitionRecord? location, bool isLast) {
      final exitingPageRoute = locationToExitingPageRoute[location];
      if (exitingPageRoute == null) return;

      if (exitingPageRoute.isWaitingForExitingDecision) {
        // Only routes still awaiting a decision are actually above this page.
        // One that was popped a moment ago is already animating out and must
        // not cost the page underneath its own transition.
        final blocking = <RouteTransitionRecord>[
          for (final pagelessRoute
              in pageRouteToPagelessRoutes[exitingPageRoute] ??
                  const <RouteTransitionRecord>[])
            if (pagelessRoute.isWaitingForExitingDecision) pagelessRoute,
        ];
        final isLastExitingPageRoute =
            isLast && !isCoveredByExiting(exitingPageRoute);

        if (isLastExitingPageRoute && blocking.isEmpty) {
          exitingPageRoute.markForPop(exitingPageRoute.route.currentResult);
        } else {
          exitingPageRoute.markForComplete(
            exitingPageRoute.route.currentResult,
          );
        }

        for (final pagelessRoute in blocking) {
          if (isLastExitingPageRoute && pagelessRoute == blocking.last) {
            pagelessRoute.markForPop(pagelessRoute.route.currentResult);
          } else {
            pagelessRoute.markForComplete(pagelessRoute.route.currentResult);
          }
        }
      }
      results.add(exitingPageRoute);

      // There may be another exiting route above this one.
      handleExitingRoute(exitingPageRoute, isLast);
    }

    handleExitingRoute(null, newPageRouteHistory.isEmpty);

    for (final pageRoute in newPageRouteHistory) {
      final isLastIteration = newPageRouteHistory.last == pageRoute;
      if (pageRoute.isWaitingForEnteringDecision) {
        if (!locationToExitingPageRoute.containsKey(pageRoute) &&
            isLastIteration) {
          pageRoute.markForPush();
        } else {
          pageRoute.markForAdd();
        }
      }
      results.add(pageRoute);
      handleExitingRoute(pageRoute, isLastIteration);
    }

    return results;
  }
}
