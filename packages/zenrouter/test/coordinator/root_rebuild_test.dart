import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// The root widget was rebuilt from scratch on every coordinator notification,
// so each one dragged the navigator, its overlay and every visible page's
// transition machinery through an update — for a widget whose every argument is
// fixed for the coordinator's life. Measured on this shape: 84 elements per
// notification, down to 7.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Shell extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(covariant TestCoordinator c) => c.inner;

  @override
  Widget build(covariant TestCoordinator c, BuildContext context) =>
      Scaffold(body: buildPath(c));
}

class Leaf extends AppRoute {
  Leaf(this.id);
  final int id;

  @override
  List<Object?> get props => [id];

  @override
  Type get layout => Shell;

  @override
  Uri toUri() => Uri.parse('/leaf/$id');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('leaf$id'));
}

class Root extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/root');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('root'));
}

class TestCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> inner =
      NavigationPath<AppRoute>.createWith(label: 'inner', coordinator: this)
        ..bindLayout(Shell.new);

  @override
  List<StackPath> get paths => [...super.paths, inner];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Root();
}

/// The widget types rebuilt while [action] runs.
Future<List<String>> rebuiltDuring(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  final names = <String>[];
  debugProfileBuildsEnabled = true;
  debugOnRebuildDirtyWidget = (element, _) =>
      names.add(element.widget.runtimeType.toString());
  await action();
  debugOnRebuildDirtyWidget = null;
  debugProfileBuildsEnabled = false;
  return names;
}

Future<TestCoordinator> pumpDeep(WidgetTester tester) async {
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  unawaited(c.replace(Root()));
  await tester.pumpAndSettle();
  unawaited(c.push(Leaf(1)));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('a notification does not put the navigator through an update', (
    tester,
  ) async {
    final c = await pumpDeep(tester);

    final rebuilt = await rebuiltDuring(tester, () async {
      c.markNeedRebuild();
      await tester.pumpAndSettle();
    });

    // Named rather than counted: the exact number moves with Flutter, but what
    // must not appear does not.
    expect(rebuilt.where((n) => n.startsWith('NavigationStack')), isEmpty);
    expect(rebuilt, isNot(contains('Navigator')));
    expect(rebuilt, isNot(contains('Overlay')));
  });

  testWidgets('and a navigation still lands', (tester) async {
    final c = await pumpDeep(tester);

    final rebuilt = await rebuiltDuring(tester, () async {
      unawaited(c.push(Leaf(2)));
      await tester.pumpAndSettle();
    });

    expect(c.currentUri.path, '/leaf/2');
    expect(find.text('leaf2'), findsOneWidget);
    expect(
      rebuilt.where((n) => n.startsWith('NavigationStack')),
      isNotEmpty,
      reason: 'the stack it renders did change',
    );
  });

  testWidgets('the root is the same widget until the table changes', (
    tester,
  ) async {
    final c = await pumpDeep(tester);
    final context = tester.element(find.byType(MaterialApp));

    final first = c.layoutBuilder(context);
    expect(identical(c.layoutBuilder(context), first), isTrue);

    // Registering a builder is what the cached widget was built from, so it has
    // to be built again — even when the builder registered is the same one.
    c.defineLayoutBuilder(c.root.pathKey, c.getLayoutBuilder(c.root.pathKey)!);

    expect(identical(c.layoutBuilder(context), first), isFalse);
  });
}
