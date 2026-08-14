import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A layout is one page to the navigator it sits on, however deep the stack it
// owns. `tryPop` knows to take the innermost path first — but a navigator asked
// directly does not, and popped the layout instead, resetting the whole section
// underneath. Every shell would have had to guard against that by hand.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

/// Sits on the root path — its own top-level section, like a settings shell.
class SectionLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(covariant TestCoordinator c) =>
      c.sectionStack;

  @override
  Widget build(covariant TestCoordinator c, BuildContext context) =>
      Scaffold(body: buildPath(c));
}

class Inner extends AppRoute {
  Inner(this.id);
  final int id;

  @override
  List<Object?> get props => [id];

  @override
  Type get layout => SectionLayout;

  @override
  Uri toUri() => Uri.parse('/section/$id');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('inner-$id'));
}

class Root extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/root');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('root'));
}

/// Guards its own pop, and is not a layout — the case that must keep working
/// exactly as it did.
class Guarded extends AppRoute with RouteGuard {
  var asked = 0;

  @override
  Uri toUri() => Uri.parse('/guarded');

  @override
  FutureOr<bool> popGuardWith(covariant Coordinator c) {
    asked++;
    return false;
  }

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('guarded'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> sectionStack =
      NavigationPath<AppRoute>.createWith(label: 'section', coordinator: this)
        ..bindLayout(SectionLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, sectionStack];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Root();
}

Future<TestCoordinator> pumpInSection(WidgetTester tester) async {
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  unawaited(c.replace(Root()));
  await tester.pumpAndSettle();
  unawaited(c.push(Inner(1)));
  await tester.pumpAndSettle();
  unawaited(c.push(Inner(2)));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('a back the root navigator receives goes to the inner stack', (
    tester,
  ) async {
    final c = await pumpInSection(tester);
    expect(c.currentUri.path, '/section/2');

    await c.navigator.maybePop();
    await tester.pumpAndSettle();

    expect(c.currentUri.path, '/section/1');
    expect(
      c.sectionStack.stack,
      hasLength(1),
      reason: 'the section was entered twice and left once',
    );
    expect(c.root.stack, hasLength(2), reason: 'still inside the section');
  });

  testWidgets('and leaves the section once there is nothing left in it', (
    tester,
  ) async {
    final c = await pumpInSection(tester);

    await c.navigator.maybePop();
    await tester.pumpAndSettle();
    await c.navigator.maybePop();
    await tester.pumpAndSettle();

    expect(c.currentUri.path, '/root');
    expect(c.root.stack, hasLength(1));
  });

  testWidgets('a page that is not a layout is left alone', (tester) async {
    // Nothing sits below it, so it neither defers nor subscribes — and its own
    // guard is still what decides.
    final c = TestCoordinator();
    await tester.pumpWidget(MaterialApp.router(routerConfig: c));
    await tester.pumpAndSettle();
    unawaited(c.replace(Root()));
    await tester.pumpAndSettle();
    final guarded = Guarded();
    unawaited(c.push(guarded));
    await tester.pumpAndSettle();

    await c.navigator.maybePop();
    await tester.pumpAndSettle();

    expect(guarded.asked, 1);
    expect(c.currentUri.path, '/guarded', reason: 'its guard refused');
  });
}
