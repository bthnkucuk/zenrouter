import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A tab list is fixed, so a tab that carries data is the *same* destination
// with different contents: `/feed?filter=new` is the feed tab, not a new one.
// The framework already handles that — the route takes the new data through
// `onUpdate` and the URL follows — but the screen has to be told, or it goes on
// showing what it was handed the first time.
// ============================================================================

/// How many times each tab's `build` ran, so "was not rebuilt" can be asserted
/// rather than implied — `Element` identity survives a rebuild, so comparing it
/// proves nothing.
final List<String> builds = [];

abstract class AppRoute extends RouteTarget with RouteUnique {}

class TabsLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  IndexedStackPath<AppRoute> resolvePath(covariant TabsCoordinator c) => c.tabs;
}

/// Its identity is "the feed tab"; the filter is data it is handed.
class FeedTab extends AppRoute with RouteGuard {
  FeedTab({this.filter = 'all'});

  String filter;

  @override
  List<Object?> get props => const [];

  @override
  Type get layout => TabsLayout;

  @override
  Uri toUri() => Uri.parse('/feed?filter=$filter');

  @override
  FutureOr<bool> popGuard() => !feedRefusesToLeave;

  @override
  void onUpdate(covariant FeedTab next) {
    super.onUpdate(next);
    filter = next.filter;
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) {
    builds.add('feed');
    return Scaffold(body: Text('feed:$filter'));
  }
}

/// Refuses to be left, so a switch away from it can be aborted mid-flight.
bool feedRefusesToLeave = false;

class OtherTab extends AppRoute {
  @override
  Type get layout => TabsLayout;

  @override
  Uri toUri() => Uri.parse('/other');

  @override
  Widget build(covariant Coordinator c, BuildContext context) {
    builds.add('other');
    return const Scaffold(body: Text('other'));
  }
}

class TabsCoordinator extends Coordinator<AppRoute> {
  TabsCoordinator({this.lazy = false});

  final bool lazy;

  late final IndexedStackPath<AppRoute> tabs = IndexedStackPath.createWith(
    coordinator: this,
    label: 'tabs',
    lazy: lazy,
    [FeedTab(), OtherTab()],
  )..bindLayout(TabsLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, tabs];

  @override
  AppRoute parseRouteFromUri(Uri uri) => FeedTab();
}

Future<TabsCoordinator> pumpApp(
  WidgetTester tester, {
  bool lazy = false,
}) async {
  final c = TabsCoordinator(lazy: lazy);
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  builds.clear();
  return c;
}

void main() {
  setUp(() => feedRefusesToLeave = false);

  group('A tab shows the data its route was handed', () {
    testWidgets('when it is the visible one', (tester) async {
      final c = await pumpApp(tester);
      expect(find.text('feed:all'), findsOneWidget);

      await c.navigate(FeedTab(filter: 'new'));
      await tester.pumpAndSettle();

      expect(find.text('feed:new'), findsOneWidget);
      expect(find.text('feed:all'), findsNothing);
      expect(c.currentUri.toString(), '/feed?filter=new');
    });

    testWidgets('and when it is not', (tester) async {
      final c = await pumpApp(tester);
      await c.tabs.goToIndexed(1);
      await tester.pumpAndSettle();

      await c.navigate(FeedTab(filter: 'archive'));
      await tester.pumpAndSettle();

      expect(find.text('feed:archive'), findsOneWidget);
    });

    testWidgets('and only that tab is rebuilt', (tester) async {
      // The refresh is per tab: an update to one must not cost the others the
      // work, or the state, that an indexed stack exists to keep.
      final c = await pumpApp(tester);

      await c.navigate(FeedTab(filter: 'new'));
      await tester.pumpAndSettle();

      expect(builds, ['feed']);
    });

    testWidgets('the same data twice still costs one rebuild', (tester) async {
      // A fresh instance is all `onUpdate` sees, so it cannot tell that the
      // data matches. Re-selecting the current tab is an ordinary gesture, and
      // this is what it costs.
      final c = await pumpApp(tester);

      await c.navigate(FeedTab());
      await tester.pumpAndSettle();

      expect(builds, ['feed']);
    });

    testWidgets('being handed itself changes nothing', (tester) async {
      // Resolving a layout activates the live instance. Nothing is transferred,
      // so nothing may be rebuilt or announced.
      final c = await pumpApp(tester);
      final live = c.tabs.stack.first;

      await c.tabs.activateRoute(live);
      await tester.pumpAndSettle();

      expect(builds, isEmpty);
    });

    testWidgets('nor one that was marked while its switch was refused', (
      tester,
    ) async {
      // `activateRoute` marks the tab it was handed *before* asking to switch,
      // and the switch can be refused — a pop guard on the tab being left. The
      // marked tab is then pending and dirty at once, and only the pending
      // check keeps it from being built by the next unrelated notification.
      final c = await pumpApp(tester, lazy: true);
      feedRefusesToLeave = true;

      await c.navigate(OtherTab());
      await tester.pumpAndSettle();
      expect(c.tabs.activeIndex, 0, reason: 'the guard refused');

      await c.navigate(FeedTab(filter: 'new'));
      await tester.pumpAndSettle();

      expect(builds, ['feed'], reason: 'the refused tab is still unbuilt');
    });

    testWidgets('lazily, an update does not materialise a pending tab', (
      tester,
    ) async {
      // The other tab has never been shown, so it is a placeholder. Refreshing
      // one tab must not build it — that would undo `lazy` on the first update
      // that came along.
      final c = await pumpApp(tester, lazy: true);

      await c.navigate(FeedTab(filter: 'new'));
      await tester.pumpAndSettle();

      expect(builds, ['feed']);
      expect(find.text('other', skipOffstage: false), findsNothing);

      await c.tabs.goToIndexed(1);
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);
    });
  });
}
