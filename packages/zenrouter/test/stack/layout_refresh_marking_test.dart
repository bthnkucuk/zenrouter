import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A layout whose shell we can count rebuilds of, plus routes that live inside
// it. Pushing one of those routes goes through `_prepareParentLayoutList`,
// which hands `pushOrMoveToTop` the *live* layout instance when the layout is
// already active — the case this file is about.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Shell extends AppRoute with RouteLayout<AppRoute> {
  static int builds = 0;
  static int updates = 0;

  @override
  NavigationPath<AppRoute> resolvePath(covariant TestCoordinator c) => c.inner;

  @override
  Uri toUri() => Uri.parse('/shell');

  @override
  void onUpdate(covariant RouteTarget newRoute) {
    super.onUpdate(newRoute);
    updates++;
  }

  @override
  Widget build(covariant TestCoordinator c, BuildContext context) {
    builds++;
    return Scaffold(body: buildPath(c));
  }
}

class Inner extends AppRoute {
  Inner(this.id, {this.note = 'none'});
  final String id;
  String note;

  @override
  Type get layout => Shell;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/shell/$id');

  @override
  void onUpdate(covariant Inner newRoute) {
    super.onUpdate(newRoute);
    note = newRoute.note;
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('inner-$id-$note'));
}

class Outside extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/outside');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('outside'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> inner = NavigationPath.createWith(
    label: 'inner',
    coordinator: this,
  )..bindLayout(Shell.new);

  @override
  List<StackPath> get paths => [...super.paths, inner];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Outside();
}

void unawaited(Future<void> f) {}

Shell shellOf(TestCoordinator c) => c.root.stack.whereType<Shell>().first;

Future<TestCoordinator> pumpApp(WidgetTester tester) async {
  Shell.builds = 0;
  Shell.updates = 0;
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  group('Refresh marking is confined to routes that actually changed', () {
    testWidgets('a nested push leaves its layout clean', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Inner('1')));
      await tester.pumpAndSettle();
      final shell = shellOf(c);
      expect(shell.needsRefresh, isFalse, reason: 'baseline');

      // The layout is already active, so this hands pushOrMoveToTop the very
      // same instance. Nothing about the layout changed.
      unawaited(c.push(Inner('2')));
      await tester.pumpAndSettle();

      expect(
        identical(shellOf(c), shell),
        isTrue,
        reason: 'the live layout instance is reused, which is the whole point',
      );
      expect(
        shell.needsRefresh,
        isFalse,
        reason: 'handing a route to itself transfers nothing, so there is '
            'nothing to rebuild for',
      );
    });

    testWidgets('and no later mutation pays for it', (tester) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Inner('1')));
      await tester.pumpAndSettle();
      unawaited(c.push(Inner('2')));
      await tester.pumpAndSettle();

      // An unrelated push on the path the layout lives on.
      Shell.builds = 0;
      unawaited(c.push(Outside()));
      await tester.pumpAndSettle();

      expect(
        Shell.builds,
        0,
        reason: 'the layout did not change, so keeping its page is correct',
      );
    });

    testWidgets('control: the same mutation without a preceding nested push', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Inner('1')));
      await tester.pumpAndSettle();

      Shell.builds = 0;
      unawaited(c.push(Outside()));
      await tester.pumpAndSettle();

      expect(
        Shell.builds,
        0,
        reason: 'the two cases must cost the same; if they diverge, the nested '
            'push is leaving state behind',
      );
    });

    testWidgets('onUpdate still runs, so its side effects are preserved', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      unawaited(c.push(Inner('1')));
      await tester.pumpAndSettle();

      final before = Shell.updates;
      unawaited(c.push(Inner('2')));
      await tester.pumpAndSettle();

      expect(
        Shell.updates,
        greaterThan(before),
        reason: 'not marking dirty must not turn into not calling onUpdate: '
            'layouts use it to refresh derived state',
      );
    });
  });

  group('A genuine update still refreshes', () {
    testWidgets('a distinct instance marks the route and repaints it', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      final inner = Inner('1', note: 'first');
      unawaited(c.push(inner));
      await tester.pumpAndSettle();
      expect(find.text('inner-1-first'), findsOneWidget);

      await c.navigate(Inner('1', note: 'second'));
      await tester.pumpAndSettle();

      expect(inner.note, 'second');
      expect(
        find.text('inner-1-second'),
        findsOneWidget,
        reason: 'this is the behaviour the marking exists for; narrowing it '
            'must not undo it',
      );
    });

    testWidgets('pushOrMoveToTop with a distinct instance still refreshes', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      final inner = Inner('1', note: 'first');
      unawaited(c.push(inner));
      await tester.pumpAndSettle();

      c.pushOrMoveToTop(Inner('1', note: 'second'));
      await tester.pumpAndSettle();

      expect(inner.note, 'second');
      expect(find.text('inner-1-second'), findsOneWidget);
    });
  });
}
