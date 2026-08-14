import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// The browser moved before the app heard about it, so anything the app reports
// back for the same URL is a second entry for one user action — and walking
// back then takes two presses per step.
// ============================================================================

/// When set, resolving the route waits on this — the shape of a redirect that
/// checks a session, or any arrival that spans frames.
Completer<void>? arrivalGate;

abstract class AppRoute extends RouteTarget with RouteUnique {}

class ItemList extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/items');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('list'));
}

class ItemDetail extends AppRoute with RouteDeepLink, RouteRedirect {
  ItemDetail(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/items/$id');

  @override
  DeeplinkStrategy get deeplinkStrategy => DeeplinkStrategy.stack;

  @override
  List<RouteUri> deeplinkStack(Uri uri) => [ItemList(), this];

  @override
  Future<RouteTarget> redirect() async {
    await arrivalGate?.future;
    return this;
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('detail-$id'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  TestCoordinator({super.initialRoutePath});

  @override
  AppRoute parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['items', final id] => ItemDetail(id),
    _ => ItemList(),
  };
}

void main() {
  late List<String> told;

  setUp(() {
    arrivalGate = null;
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

  /// What the browser does: hand the URL to the app the way
  /// `PlatformRouteInformationProvider` receives it. Going through the channel
  /// is what makes the difference visible — Flutter suppresses a report that
  /// matches the URI the platform last supplied, and suppressing it is the
  /// whole point.
  Future<void> browserSends(WidgetTester tester, String uri) {
    return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(
        MethodCall('pushRouteInformation', {'location': uri}),
      ),
      (_) {},
    );
  }

  Future<TestCoordinator> pumpAt(WidgetTester tester, String uri) async {
    final c = TestCoordinator(initialRoutePath: Uri.parse(uri));
    await tester.pumpWidget(MaterialApp.router(routerConfig: c));
    await tester.pumpAndSettle();
    told.clear();
    return c;
  }

  group('A deep link does not add the entry the browser already made', () {
    testWidgets('when it lands at once', (tester) async {
      await pumpAt(tester, '/items/1');

      await browserSends(tester, '/items/2');
      await tester.pumpAndSettle();

      expect(told, ['/items/2 replace=true']);
    });

    testWidgets('nor when the arrival spans frames', (tester) async {
      // The gap is what exposed this: the router reports the moment
      // `setNewRoutePath` returns, and an arrival that is still resolving
      // leaves the app sitting on the old URI at that moment. Reporting *that*
      // wrote an entry for a screen the user never saw.
      final c = await pumpAt(tester, '/items/1');
      arrivalGate = Completer<void>();

      unawaited(browserSends(tester, '/items/2'));
      await tester.pumpAndSettle();
      expect(told, isEmpty, reason: 'nothing has landed yet');

      arrivalGate!.complete();
      await tester.pumpAndSettle();

      expect(told, ['/items/2 replace=true']);
      expect(c.root.stack.map((r) => r.toUri().path), ['/items', '/items/2']);
    });
  });
}
