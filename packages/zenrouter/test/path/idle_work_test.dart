import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Work that a navigation should not cost: a notification for an update that
// transferred nothing, and a listenable adapter rebuilt on every frame.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Leaf extends AppRoute {
  Leaf(this.id);
  final int id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/leaf/$id');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('leaf-$id'));
}

/// Exposes a listenable through a getter, which is how an app writes it — and
/// which is why the adapter around it must not be rebuilt per read.
class Guarded extends AppRoute with RouteGuard {
  final dirty = ValueNotifier(false);

  @override
  Uri toUri() => Uri.parse('/guarded');

  @override
  ListenableMixin? get canPopListenable => dirty.toListenableMixin();

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('guarded'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => Leaf(0);
}

void main() {
  group('An update that transferred nothing is not announced', () {
    late List<String> told;

    setUp(() {
      told = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.navigation, (call) async {
            if (call.method == 'routeInformationUpdated') told.add('update');
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.navigation, null);
    });

    testWidgets('navigating to the instance already on top', (tester) async {
      // Resolving a layout does exactly this, and so does restoring: the live
      // route is handed to `navigate`. There is nothing to rebuild and nothing
      // to tell the browser, which is already showing this URI.
      final c = TestCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();
      final live = Leaf(1);
      unawaited(c.push(live));
      await tester.pumpAndSettle();

      var notifications = 0;
      c.addListener(() => notifications++);
      told.clear();

      await c.navigate(live);
      await tester.pumpAndSettle();

      expect(notifications, 0);
      expect(told, isEmpty);
    });

    testWidgets('but an equal, distinct one still is', (tester) async {
      // A fresh instance may carry new data, and `onUpdate` is what transfers
      // it — so the screen and the URL both have to hear about it.
      final c = TestCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();
      unawaited(c.push(Leaf(1)));
      await tester.pumpAndSettle();

      var notifications = 0;
      c.addListener(() => notifications++);
      told.clear();

      await c.navigate(Leaf(1));
      await tester.pumpAndSettle();

      expect(notifications, 1);
      expect(told, hasLength(1));
    });
  });

  group('Wrapping a listenable hands back the same wrapper', () {
    test('in both directions', () {
      // These conversions live in getters that are read on every build. A fresh
      // wrapper each time is a different object to `ListenableBuilder`, which
      // then drops its listener and re-registers it every frame.
      final notifier = ValueNotifier(false);
      final mixin = notifier.toListenableMixin();

      expect(identical(notifier.toListenableMixin(), mixin), isTrue);
      expect(
        identical(mixin.toFlutterListenable(), mixin.toFlutterListenable()),
        isTrue,
      );

      notifier.dispose();
    });

    testWidgets('so a rebuild does not churn the guard listener', (
      tester,
    ) async {
      final c = TestCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();
      final guarded = Guarded();
      unawaited(c.push(guarded));
      await tester.pumpAndSettle();

      final first = guarded.canPopListenable!.toFlutterListenable();
      c.markNeedRebuild();
      await tester.pumpAndSettle();

      expect(
        identical(guarded.canPopListenable!.toFlutterListenable(), first),
        isTrue,
      );
    });
  });
}
