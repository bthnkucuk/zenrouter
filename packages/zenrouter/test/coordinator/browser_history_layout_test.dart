import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A layout chain shaped like the coordinator example: a NavigationPath shell
// wrapping an IndexedStackPath of tabs. `replace` onto a tab therefore has to
// activate two layouts before it reaches the route.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class HomeLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(covariant TabCoordinator coordinator) =>
      coordinator.homeStack;

  @override
  Widget build(covariant TabCoordinator coordinator, BuildContext context) =>
      Scaffold(body: buildPath(coordinator));
}

class TabBarLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  Type get layout => HomeLayout;

  @override
  IndexedStackPath<AppRoute> resolvePath(
    covariant TabCoordinator coordinator,
  ) => coordinator.tabIndexed;

  @override
  Widget build(covariant TabCoordinator coordinator, BuildContext context) =>
      Scaffold(body: buildPath(coordinator));
}

class FeedTab extends AppRoute {
  @override
  Type get layout => TabBarLayout;

  @override
  Uri toUri() => Uri.parse('/home/tabs/feed');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Scaffold(body: Text('feed'));
}

class SettingsTab extends AppRoute {
  @override
  Type get layout => TabBarLayout;

  @override
  Uri toUri() => Uri.parse('/home/tabs/settings');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Scaffold(body: Text('settings'));
}

class Login extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/login');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Scaffold(body: Text('login'));
}

class TabCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> homeStack = NavigationPath.createWith(
    label: 'home',
    coordinator: this,
  )..bindLayout(HomeLayout.new);

  late final IndexedStackPath<AppRoute> tabIndexed =
      IndexedStackPath.createWith(coordinator: this, label: 'home-tabs', [
        FeedTab(),
        SettingsTab(),
      ])..bindLayout(TabBarLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, homeStack, tabIndexed];

  @override
  AppRoute parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['home', 'tabs', 'feed'] => FeedTab(),
    ['home', 'tabs', 'settings'] => SettingsTab(),
    _ => Login(),
  };
}

void unawaited(Future<void> f) {}

class HistoryRecorder {
  final entries = <({String uri, bool replace})>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (call) async {
        if (call.method == 'routeInformationUpdated') {
          final args = (call.arguments as Map).cast<String, Object?>();
          entries.add((
            uri: args['uri']! as String,
            replace: args['replace'] == true,
          ));
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        null,
      ),
    );
  }

  List<String> get pushed =>
      [for (final e in entries) if (!e.replace) e.uri];

  void clear() => entries.clear();
}

void main() {
  group('Browser history with layouts', () {
    testWidgets('replace onto a layout-parented route adds no entry', (
      tester,
    ) async {
      final rec = HistoryRecorder()..install(tester);
      final c = TabCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      // Sit on a tab, then visit login — the flow the example demonstrates.
      unawaited(c.push(SettingsTab()));
      await tester.pumpAndSettle();
      unawaited(c.push(Login()));
      await tester.pumpAndSettle();
      rec.clear();

      // "Signing in" resets the stack onto a tab, which means activating the
      // HomeLayout and TabBarLayout on the way.
      await c.replace(FeedTab());
      await tester.pumpAndSettle();

      expect(rec.entries, isNotEmpty, reason: 'the new URI must be reported');
      expect(
        rec.pushed,
        isEmpty,
        reason: 'replace discarded the old stack, including /login; the layout '
            'activations it performs must not add entries either',
      );
    });

    testWidgets('a push after a layout replace still adds an entry', (
      tester,
    ) async {
      final rec = HistoryRecorder()..install(tester);
      final c = TabCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      await c.replace(FeedTab());
      await tester.pumpAndSettle();
      rec.clear();

      unawaited(c.push(SettingsTab()));
      await tester.pumpAndSettle();

      expect(
        rec.pushed,
        isNotEmpty,
        reason: 'the replace intent must not leak into ordinary navigation',
      );
    });

    testWidgets('the coordinator provider reports whether it was wired', (
      tester,
    ) async {
      // Delegate + parser but no provider: Flutter builds its own, so the
      // coordinator's never gets to mark a replacement. On web the delegate
      // reports this as a framework error; here we pin the signal it uses.
      final unwired = TabCoordinator();
      addTearDown(unwired.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerDelegate: unwired.routerDelegate,
          routeInformationParser: unwired.routeInformationParser,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        (unwired.routeInformationProvider
                as CoordinatorRouteInformationProvider)
            .isAttached,
        isFalse,
        reason: 'no Router subscribed to it, so history handling cannot run',
      );

      final wired = TabCoordinator();
      addTearDown(wired.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: wired));
      await tester.pumpAndSettle();

      expect(
        (wired.routeInformationProvider as CoordinatorRouteInformationProvider)
            .isAttached,
        isTrue,
      );
    });

    testWidgets('push onto a layout-parented route adds an entry', (
      tester,
    ) async {
      final rec = HistoryRecorder()..install(tester);
      final c = TabCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();
      rec.clear();

      unawaited(c.push(FeedTab()));
      await tester.pumpAndSettle();

      expect(rec.pushed, isNotEmpty, reason: 'forward navigation is an entry');
    });
  });
}
