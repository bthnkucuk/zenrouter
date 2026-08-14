import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Tabs are siblings in one subtree, so their restorable state needs somewhere
// of its own to live. A `NavigationPath` gets that from its `Navigator`'s
// restoration scope; an indexed path has no navigator, so the builder wraps
// each tab in a scope of its own.
//
// That is not a nicety: `restorationId: 'field'` is exactly what a form widget
// shared between tabs would use, and with one scope for all of them both tabs
// ask the same bucket for their state.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

/// A tab whose content owns restorable state under a fixed id — deliberately
/// the same id in every tab.
class FormTab extends AppRoute {
  FormTab(this.name);
  final String name;

  @override
  List<Object?> get props => [name];

  @override
  Type get layout => TabsLayout;

  @override
  Uri toUri() => Uri.parse('/tabs/$name');

  @override
  Widget build(covariant Coordinator c, BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('tab-$name'),
        SizedBox(
          height: 60,
          child: TextField(key: Key('field-$name'), restorationId: 'field'),
        ),
      ],
    ),
  );
}

/// Both coordinators below own a tab path, so the layout can resolve either.
abstract interface class HasTabs {
  IndexedStackPath<AppRoute> get tabs;
}

class TabsLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  IndexedStackPath<AppRoute> resolvePath(covariant Coordinator c) =>
      (c as HasTabs).tabs;
}

class TabsCoordinator extends Coordinator<AppRoute> implements HasTabs {
  TabsCoordinator({this.lazy = false});

  final bool lazy;

  @override
  late final IndexedStackPath<AppRoute> tabs =
      IndexedStackPath.createWith(
        coordinator: this,
        label: 'tabs',
        lazy: lazy,
        [FormTab('a'), FormTab('b')],
      )..bindLayout(TabsLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, tabs];

  @override
  AppRoute parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['tabs', final name] => FormTab(name),
    _ => FormTab('a'),
  };
}

/// A path with no label, used directly rather than through a coordinator.
class UnlabelledCoordinator extends Coordinator<AppRoute> implements HasTabs {
  @override
  late final IndexedStackPath<AppRoute> tabs =
      IndexedStackPath.create([
        FormTab('a'),
        FormTab('b'),
      ], coordinator: this)..bindLayout(TabsLayout.new);

  @override
  AppRoute parseRouteFromUri(Uri uri) => FormTab('a');
}

Finder fieldIn(String tab) =>
    find.byKey(Key('field-$tab'), skipOffstage: false);

/// What a tab's field holds, read straight off its controller so a hidden tab
/// can be inspected too — `find.text` only sees the visible one.
String textIn(WidgetTester tester, String tab) => tester
    .widget<EditableText>(
      find.descendant(
        of: fieldIn(tab),
        matching: find.byType(EditableText, skipOffstage: false),
      ),
    )
    .controller
    .text;

/// Types into a tab the way a user would: by looking at it first.
///
/// `enterText` drives the platform text input, which belongs to the *focused*
/// field. An offstage one never gets it and the text lands in the visible tab
/// instead — quietly, which is worth knowing before writing a tab test.
Future<void> typeInto(
  WidgetTester tester,
  TabsCoordinator c,
  int index,
  String tab,
  String text,
) async {
  await c.tabs.goToIndexed(index);
  await tester.pumpAndSettle();
  await tester.enterText(fieldIn(tab), text);
  await tester.pumpAndSettle();
}

Future<TabsCoordinator> pumpApp(WidgetTester tester, {bool lazy = false}) async {
  final c = TabsCoordinator(lazy: lazy);
  await tester.pumpWidget(
    MaterialApp.router(restorationScopeId: 'app', routerConfig: c),
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  group('An indexed path restores what its tabs hold', () {
    testWidgets('the visible tab keeps its state across a restart', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      await tester.enterText(fieldIn('a'), 'typed in a');
      await tester.pumpAndSettle();

      await tester.restartAndRestore();
      await tester.pumpAndSettle();

      expect(textIn(tester, 'a'), 'typed in a');
      expect(c.tabs.activeIndex, 0);
    });

    testWidgets('so does a tab that is hidden when the restart happens', (
      tester,
    ) async {
      final c = await pumpApp(tester);
      await typeInto(tester, c, 1, 'b', 'written in b');
      await c.tabs.goToIndexed(0);
      await tester.pumpAndSettle();

      await tester.restartAndRestore();
      await tester.pumpAndSettle();

      expect(textIn(tester, 'b'), 'written in b');
    });

    testWidgets('two tabs under the same restoration id keep their own', (
      tester,
    ) async {
      // Without a scope per tab both fields register under one bucket, so they
      // come back holding the same text — silently, whichever wrote last.
      final c = await pumpApp(tester);
      await tester.enterText(fieldIn('a'), 'alpha');
      await tester.pumpAndSettle();
      await typeInto(tester, c, 1, 'b', 'beta');
      await c.tabs.goToIndexed(0);
      await tester.pumpAndSettle();

      await tester.restartAndRestore();
      await tester.pumpAndSettle();

      expect(textIn(tester, 'a'), 'alpha');
      expect(textIn(tester, 'b'), 'beta');
    });

    testWidgets('the active tab is restored with them', (tester) async {
      final c = await pumpApp(tester);
      await typeInto(tester, c, 1, 'b', 'beta');

      await tester.restartAndRestore();
      await tester.pumpAndSettle();

      expect(c.tabs.activeIndex, 1);
      expect(textIn(tester, 'b'), 'beta');
    });

    testWidgets('switching tabs still rebuilds nothing', (tester) async {
      // The scopes wrap the cached children, so they must not defeat the cache.
      final c = await pumpApp(tester);
      await tester.enterText(fieldIn('a'), 'kept');
      await tester.pumpAndSettle();

      await c.tabs.goToIndexed(1);
      await tester.pumpAndSettle();
      await c.tabs.goToIndexed(0);
      await tester.pumpAndSettle();

      expect(
        textIn(tester, 'a'),
        'kept',
        reason: 'the tab was never rebuilt, so its field kept its text',
      );
    });
  });

  group('A lazy path restores a tab it builds later', () {
    testWidgets('the tab picks up its state when it is first opened', (
      tester,
    ) async {
      // The state is in the bucket from the moment the app comes back; the tab
      // that reads it just does not exist yet. Building it later must still
      // find it.
      final c = await pumpApp(tester, lazy: true);
      await typeInto(tester, c, 1, 'b', 'beta');
      await c.tabs.goToIndexed(0);
      await tester.pumpAndSettle();
      await tester.enterText(fieldIn('a'), 'alpha');
      await tester.pumpAndSettle();

      await tester.restartAndRestore();
      await tester.pumpAndSettle();

      expect(textIn(tester, 'a'), 'alpha', reason: 'the tab it landed on');

      await c.tabs.goToIndexed(1);
      await tester.pumpAndSettle();

      expect(
        textIn(tester, 'b'),
        'beta',
        reason: 'built only now, and still holding what it had',
      );
    });
  });

  group('Without a restoration id to key a tab by', () {
    testWidgets('an unlabelled path renders instead of throwing', (
      tester,
    ) async {
      // A route's restoration id spells out the paths it sits under, so they
      // must be labelled. A path registered on a coordinator always is, but the
      // widget can be used on its own with one that is not — and asking on a
      // route's behalf must not turn that into a crash.
      final c = UnlabelledCoordinator();
      await tester.pumpWidget(
        MaterialApp(
          restorationScopeId: 'app',
          home: IndexedStackPathBuilder(path: c.tabs, coordinator: c),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('tab-a'), findsOneWidget);
    });
  });

  group('Without restoration configured', () {
    testWidgets('the tabs still render and switch', (tester) async {
      // No `restorationScopeId` on the app: every scope resolves to null and
      // restoration is simply off. Nothing may crash.
      final c = TabsCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      expect(find.text('tab-a'), findsOneWidget);

      await c.tabs.goToIndexed(1);
      await tester.pumpAndSettle();

      expect(find.text('tab-b'), findsOneWidget);
    });
  });
}
