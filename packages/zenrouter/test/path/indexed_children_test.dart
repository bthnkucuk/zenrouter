import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// An indexed stack keeps every tab alive, so its children are built once and
// reused — switching tabs must rebuild nothing. "Once" is per set of tabs
// though: handed a different path, the widget has to let the old tabs go.
// ============================================================================

final List<String> built = [];

class Tab extends RouteTarget with RouteUnique {
  Tab(this.name);
  final String name;

  @override
  List<Object?> get props => [name];

  @override
  Uri toUri() => Uri.parse('/$name');

  @override
  Widget build(covariant Coordinator c, BuildContext context) {
    built.add(name);
    return Scaffold(body: Center(child: Text('tab-$name')));
  }
}

class TestCoordinator extends Coordinator<RouteUnique> {
  @override
  RouteUnique parseRouteFromUri(Uri uri) => Tab('a');
}

/// Rebuilt on demand so the builder can be handed a different path.
class Host extends StatefulWidget {
  const Host({super.key, required this.coordinator, required this.path});

  final TestCoordinator coordinator;
  final IndexedStackPath<RouteUnique> path;

  @override
  State<Host> createState() => HostState();
}

class HostState extends State<Host> {
  late IndexedStackPath<RouteUnique> path = widget.path;

  void swap(IndexedStackPath<RouteUnique> next) => setState(() => path = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: ListenableBuilder(
      listenable: path,
      builder: (context, _) =>
          IndexedStackPathBuilder(path: path, coordinator: widget.coordinator),
    ),
  );
}

void main() {
  setUp(built.clear);

  testWidgets('switching tabs rebuilds nothing', (tester) async {
    final c = TestCoordinator();
    final path = IndexedStackPath<RouteUnique>.createWith([
      Tab('a'),
      Tab('b'),
    ], coordinator: c, label: 'tabs');

    await tester.pumpWidget(Host(coordinator: c, path: path));
    await tester.pumpAndSettle();
    expect(built, ['a', 'b'], reason: 'every tab is mounted up front');
    built.clear();

    await path.goToIndexed(1);
    await tester.pumpAndSettle();

    expect(
      built,
      isEmpty,
      reason: 'the tabs are alive already; switching only changes which one '
          'is painted',
    );
    expect(find.text('tab-b'), findsOneWidget);
  });

  testWidgets('a different path replaces the tabs', (tester) async {
    final c = TestCoordinator();
    final first = IndexedStackPath<RouteUnique>.createWith([
      Tab('a'),
      Tab('b'),
    ], coordinator: c, label: 'first');
    final second = IndexedStackPath<RouteUnique>.createWith([
      Tab('x'),
      Tab('y'),
    ], coordinator: c, label: 'second');

    final key = GlobalKey<HostState>();
    await tester.pumpWidget(Host(key: key, coordinator: c, path: first));
    await tester.pumpAndSettle();
    built.clear();

    key.currentState!.swap(second);
    await tester.pumpAndSettle();

    expect(built, ['x', 'y']);
    expect(find.text('tab-x'), findsOneWidget);
    expect(
      find.text('tab-a', skipOffstage: false),
      findsNothing,
      reason: 'the first path\'s tabs must not stay mounted underneath',
    );
  });
}
