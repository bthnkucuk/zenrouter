import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A freshly loaded page must take one back press to leave, not two. Working out
// which route the launch URI means is the app settling on where it already is —
// the browser is showing that page already — so it overwrites the entry.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Login extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/login');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('login'));
}

class Detail extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/detail');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('detail'));
}

/// The launch URI is `/`, and the app resolves it to a route with a different
/// URI — the redirect-at-launch shape almost every real app has.
class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['detail'] => Detail(),
    _ => Login(),
  };
}

void main() {
  late List<String> told;

  setUp(() {
    told = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.navigation, (call) async {
          if (call.method == 'routeInformationUpdated') {
            final args = call.arguments as Map;
            told.add('${args['uri']} replace=${args['replace']}');
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.navigation, null);
  });

  testWidgets('a cold start adds no history entry of its own', (tester) async {
    final c = TestCoordinator();
    await tester.pumpWidget(MaterialApp.router(routerConfig: c));
    await tester.pumpAndSettle();

    expect(
      told.every((entry) => entry.endsWith('replace=true')),
      isTrue,
      reason: 'the route the launch URI resolves to overwrites it: $told',
    );
    expect(find.text('login'), findsOneWidget);
  });

  testWidgets('and a navigation afterwards still adds one', (tester) async {
    // The launch is the only thing that replaces. What the user does next is a
    // real navigation and has to be reachable by pressing back.
    final c = TestCoordinator();
    await tester.pumpWidget(MaterialApp.router(routerConfig: c));
    await tester.pumpAndSettle();
    told.clear();

    // Not awaited: a push settles when its route is popped.
    unawaited(c.push(Detail()));
    await tester.pumpAndSettle();

    expect(told, ['/detail replace=false']);
  });
}
