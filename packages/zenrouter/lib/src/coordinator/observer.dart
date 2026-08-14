import 'package:flutter/cupertino.dart';
import 'package:zenrouter/zenrouter.dart';

/// Mixin that provides a list of observers for the coordinator's navigator.
///
/// ## Role in Navigation Flow
///
/// [CoordinatorNavigatorObserver] enables observability of navigation events:
/// 1. Observers are attached to each [NavigationStack] in the coordinator
/// 2. Flutter's Navigator notifies observers of route changes
/// 3. Useful for analytics, logging, or custom behavior on navigation events
///
/// Common observers include:
/// - [NavigatorObserver] - Base class for navigation observation
/// - [RouteObserver] - Notifies when routes are pushed/popped
mixin CoordinatorNavigatorObserver<T extends RouteUnique> on Coordinator<T> {
  /// Builds the observers for one [Navigator].
  ///
  /// Called once per navigator, and the result is kept for that navigator's
  /// lifetime — so observers accumulate state as their navigator does, which is
  /// what analytics counters and [RouteObserver] subscriptions rely on.
  ///
  /// It has to be a builder rather than a list because a coordinator runs
  /// several navigators at once — one per layout — and Flutter binds an
  /// observer to exactly one of them ([NavigatorState.initState] asserts
  /// `observer.navigator == null`). Sharing instances across layouts trips that
  /// assert in debug and, in release, silently reassigns the observer so the
  /// navigator that had it stops being reported on.
  ///
  /// ```dart
  /// @override
  /// NavigatorObserverListGetter get observersBuilder => () => [MyAnalytics()];
  /// ```
  NavigatorObserverListGetter get observersBuilder =>
      kEmptyNavigatorObserverList;

  /// A list of observers that apply for every [NavigationPath] in the coordinator.
  @Deprecated(
    'Use observersBuilder instead. A single list is shared by every navigator '
    'the coordinator runs, which Flutter forbids: an observer belongs to one '
    'navigator. Return a builder so each navigator gets its own instances. '
    'This will be removed in the next major.',
  )
  List<NavigatorObserver> get observers => const [];
}

typedef NavigatorObserverListGetter = List<NavigatorObserver> Function();

List<NavigatorObserver> kEmptyNavigatorObserverList() => [];
