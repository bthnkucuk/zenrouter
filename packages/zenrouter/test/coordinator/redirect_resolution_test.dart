import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Test Routes
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

/// An auth-style redirect: lets the route through when signed in, diverts to
/// login otherwise. Counts how often the decision is actually taken, since that
/// is where a real app puts a service call.
class Guarded extends AppRoute with RouteRedirect<AppRoute> {
  Guarded(this.id);
  final String id;

  static int checks = 0;
  static bool signedIn = true;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/guarded/$id');

  @override
  FutureOr<AppRoute?> redirectWith(covariant Coordinator coordinator) {
    checks++;
    return signedIn ? this : Login();
  }

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      Scaffold(body: Text('guarded-$id'));
}

/// Redirects onward to a third route, to check chains still resolve.
class Hop extends AppRoute with RouteRedirect<AppRoute> {
  static int checks = 0;

  @override
  Uri toUri() => Uri.parse('/hop');

  @override
  FutureOr<AppRoute?> redirectWith(covariant Coordinator coordinator) {
    checks++;
    return Guarded('via-hop');
  }

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Scaffold(body: Text('hop'));
}

class Login extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/login');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Scaffold(body: Text('login'));
}

class Home extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Scaffold(body: Text('home'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => Home();
}

void unawaited(Future<void> f) {}

Future<TestCoordinator> pumpApp(WidgetTester tester) async {
  Guarded.checks = 0;
  Hop.checks = 0;
  Guarded.signedIn = true;
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  Guarded.checks = 0;
  return c;
}

void main() {
  group('A redirect decides once per navigation', () {
    testWidgets('push', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Guarded('1')));
      await tester.pumpAndSettle();
      expect(
        Guarded.checks,
        1,
        reason: 'the coordinator resolves, then the path resolved again',
      );
    });

    testWidgets('navigate', (tester) async {
      final c = await pumpApp(tester);
      await c.navigate(Guarded('1'));
      await tester.pumpAndSettle();
      expect(
        Guarded.checks,
        1,
        reason: 'coordinator, then navigate, then the push it falls through to',
      );
    });

    testWidgets('pushOrMoveToTop', (tester) async {
      final c = await pumpApp(tester);
      c.pushOrMoveToTop(Guarded('1'));
      await tester.pumpAndSettle();
      expect(Guarded.checks, 1);
    });

    testWidgets('replace', (tester) async {
      final c = await pumpApp(tester);
      await c.replace(Guarded('1'));
      await tester.pumpAndSettle();
      expect(Guarded.checks, 1);
    });

    testWidgets('a path used directly was always right', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.root.push(Guarded('1')));
      await tester.pumpAndSettle();
      expect(Guarded.checks, 1, reason: 'the single-resolve baseline');
    });
  });

  group('Redirects still redirect', () {
    testWidgets('a diverted route lands on its destination', (tester) async {
      final c = await pumpApp(tester);
      Guarded.signedIn = false;

      unawaited(c.push(Guarded('secret')));
      await tester.pumpAndSettle();

      expect(find.text('login'), findsOneWidget);
      expect(c.root.stack.whereType<Login>().length, 1);
      expect(c.root.stack.whereType<Guarded>(), isEmpty);
    });

    testWidgets('a chain resolves all the way through', (tester) async {
      final c = await pumpApp(tester);

      unawaited(c.push(Hop()));
      await tester.pumpAndSettle();

      expect(find.text('guarded-via-hop'), findsOneWidget);
      expect(Hop.checks, 1);
      expect(
        Guarded.checks,
        1,
        reason: 'each link in the chain decides once, not once per layer',
      );
    });

    testWidgets('a redirect that changes its mind between navigations', (
      tester,
    ) async {
      final c = await pumpApp(tester);

      unawaited(c.push(Guarded('1')));
      await tester.pumpAndSettle();
      expect(find.text('guarded-1'), findsOneWidget);

      // Session expires; the next navigation must take the new decision.
      Guarded.signedIn = false;
      unawaited(c.push(Guarded('2')));
      await tester.pumpAndSettle();

      expect(
        find.text('login'),
        findsOneWidget,
        reason: 'resolving once per navigation must not mean caching the '
            'decision across navigations',
      );
    });
  });
}
