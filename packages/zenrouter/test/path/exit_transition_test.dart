import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A page that leaves the stack plays its exit transition. Flutter's default
// delegate drops that transition whenever anything else is above the page —
// including a dialog that is already closing, which is what every pop guard
// produces.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Home extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Center(child: Text('home')));
}

/// A dialog written as a route: its [DialogRoute] is not opaque, so it sits
/// over the page below without covering it.
class ConfirmRoute extends AppRoute with RouteTransition {
  @override
  Uri toUri() => Uri.parse('/confirm');

  @override
  StackTransition<R> transition<R extends RouteUnique>(
    covariant Coordinator c,
  ) => StackTransition.dialog(Builder(builder: (ctx) => build(c, ctx)));

  @override
  Widget build(covariant Coordinator c, BuildContext context) => AlertDialog(
    title: const Text('leave?'),
    actions: [
      TextButton(onPressed: () => c.pop(true), child: const Text('yes')),
    ],
  );
}

class Editor extends AppRoute with RouteGuard {
  Editor({this.guarded = false});

  final bool guarded;

  @override
  List<Object?> get props => [guarded];

  @override
  Uri toUri() => Uri.parse('/editor');

  @override
  Future<bool> popGuardWith(covariant Coordinator c) async {
    if (!guarded) return true;
    final answer = await showDialog<bool>(
      context: c.navigator.context,
      builder: (context) => AlertDialog(
        title: const Text('leave?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('yes'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('EDITOR')),
    body: Center(
      child: TextButton(
        onPressed: () async {
          final leave = await c.push<bool>(ConfirmRoute());
          if (leave == true) c.pop();
        },
        child: const Text('leave'),
      ),
    ),
  );
}

/// An ordinary opaque screen, to check the default rule still holds.
class Details extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/details');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Center(child: Text('details')));
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) => Home();
}

/// How far the editor's title travels over the frames after it starts leaving,
/// or `null` if the page was gone before the first of them. A transition moves
/// it; a bare removal leaves it where it was, or takes it away at once.
///
/// The two "did not animate" outcomes are kept apart on purpose: a test that
/// expects movement must not pass because the page was never there.
Future<double?> travelled(WidgetTester tester) async {
  final finder = find.text('EDITOR');
  if (finder.evaluate().isEmpty) return null;
  final start = tester.getTopLeft(finder).dx;
  var furthest = start;
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isEmpty) break;
    furthest = tester.getTopLeft(finder).dx;
  }
  return furthest - start;
}

Future<TestCoordinator> pumpWith(WidgetTester tester, Editor editor) async {
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  unawaited(c.push(editor));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  group('A page leaving the stack plays its exit transition', () {
    testWidgets('with nothing above it', (tester) async {
      final c = await pumpWith(tester, Editor());

      unawaited(c.pop());
      await tester.pump();

      expect(await travelled(tester), greaterThan(50));
    });

    testWidgets('while a guard dialog is closing above it', (tester) async {
      // The guard's dialog is pushed imperatively, so the page carries a
      // "pageless" route. Flutter completes such a page instead of popping it —
      // but this dialog was dismissed a moment ago and is on its way out.
      final c = await pumpWith(tester, Editor(guarded: true));

      unawaited(c.pop());
      await tester.pumpAndSettle();
      expect(find.text('leave?'), findsOneWidget);
      await tester.tap(find.text('yes'));
      await tester.pump();

      expect(await travelled(tester), greaterThan(50));
    });

    testWidgets('while a dialog route leaves with it', (tester) async {
      // The same dialog written as a route: two pages leave at once, and the
      // one on top is a [DialogRoute], which never covered the page below.
      final c = await pumpWith(tester, Editor());

      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('yes'));
      await tester.pump();

      expect(await travelled(tester), greaterThan(50));
      await tester.pumpAndSettle();
      expect(c.root.stack.map((r) => r.toUri().path), ['/']);
    });
  });

  testWidgets('an opaque page above it still takes the transition', (
    tester,
  ) async {
    // Flutter's rule, kept: when several ordinary screens leave together only
    // the top one animates, since the others are not on screen to animate.
    final c = await pumpWith(tester, Editor());
    unawaited(c.push(Details()));
    await tester.pumpAndSettle();

    c.root.applyStack([Home()]);
    await tester.pump();

    final moved = await travelled(tester);
    expect(
      moved == null || moved == 0,
      isTrue,
      reason:
          'the editor was hidden behind the details screen, so it has no '
          'transition to play — it either stays put or is gone at once, '
          'but it must not slide (was $moved)',
    );
  });
}
