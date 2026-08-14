import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A route is discarded once, however it leaves. `onDiscard` is where an app
// releases what the route owns, so running it twice disposes a controller
// twice — and a route can leave through two doors at once: the path removes and
// discards it, and its page reports the pop afterwards.
// ============================================================================

int discards = 0;

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Home extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('home'));
}

/// Owns something it releases on the way out, the way a form owns its
/// controller.
class Editor extends AppRoute {
  final dirty = ValueNotifier(false);

  @override
  Uri toUri() => Uri.parse('/editor');

  @override
  void onDiscard() {
    discards++;
    dirty.dispose();
    super.onDiscard();
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(appBar: AppBar(title: const Text('EDITOR')));
}

/// Not opaque, so the page below it still animates out — which is what puts
/// that page through the pop reporting it used to skip.
class ConfirmRoute extends AppRoute with RouteTransition {
  @override
  Uri toUri() => Uri.parse('/confirm');

  @override
  StackTransition<T> transition<T extends RouteUnique>(
    covariant Coordinator c,
  ) => StackTransition.dialog(Builder(builder: (ctx) => build(c, ctx)));

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const AlertDialog(title: Text('confirm'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => Home();
}

Future<TestCoordinator> pumpWithEditor(WidgetTester tester) async {
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  unawaited(c.push(Editor()));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  setUp(() => discards = 0);

  group('A route is discarded exactly once', () {
    testWidgets('when the coordinator pops it', (tester) async {
      final c = await pumpWithEditor(tester);

      unawaited(c.pop());
      await tester.pumpAndSettle();

      expect(discards, 1);
    });

    testWidgets('when a widget pops it', (tester) async {
      final c = await pumpWithEditor(tester);

      Navigator.of(c.navigator.context).pop();
      await tester.pumpAndSettle();

      expect(discards, 1);
    });

    testWidgets('when a declarative update drops it', (tester) async {
      // `applyStack` removes and discards in one step, and the page still
      // reports its pop afterwards.
      final c = await pumpWithEditor(tester);
      final home = c.root.stack.first;

      c.root.applyStack([home]);
      await tester.pumpAndSettle();

      expect(discards, 1);
    });

    testWidgets('when it is dropped from under a leaving dialog route', (
      tester,
    ) async {
      final c = await pumpWithEditor(tester);
      final home = c.root.stack.first;
      unawaited(c.push(ConfirmRoute()));
      await tester.pumpAndSettle();

      c.root.applyStack([home]);
      await tester.pumpAndSettle();

      expect(discards, 1);
    });

    testWidgets('and its result still arrives', (tester) async {
      final c = TestCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();
      Object? received;
      unawaited(c.push(Editor()).then((value) => received = value));
      await tester.pumpAndSettle();

      unawaited(c.pop('saved'));
      await tester.pumpAndSettle();

      expect(received, 'saved');
      expect(discards, 1);
    });
  });
}
