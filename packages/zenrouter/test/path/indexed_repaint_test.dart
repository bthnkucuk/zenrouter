import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A tab shares a painting layer with the shell around it, so an animation
// inside one tab repaints the tab bar and its siblings every frame along with
// itself. `isolateRepaints` puts a boundary at the tab's edge.
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class Tab extends AppRoute {
  Tab(this.name, {this.animates = false});
  final String name;
  final bool animates;

  @override
  List<Object?> get props => [name];

  @override
  Type get layout => TabsLayout;

  @override
  Uri toUri() => Uri.parse('/$name');

  @override
  Widget build(covariant Coordinator c, BuildContext context) => Scaffold(
    body: animates ? const Spinner() : Center(child: Text('tab-$name')),
  );
}

/// Something that repaints on every frame, which is what makes the difference
/// between the two modes observable at all.
class Spinner extends StatefulWidget {
  const Spinner({super.key});

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..repeat();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RotationTransition(turns: controller, child: const Icon(Icons.sync));
}

class TabsLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  IndexedStackPath<AppRoute> resolvePath(covariant TestCoordinator c) => c.tabs;

  @override
  Widget build(covariant TestCoordinator c, BuildContext context) => Scaffold(
    body: buildPath(c),
    // The shell around the tabs: what should not be repainting because a tab is.
    bottomNavigationBar: const SizedBox(height: 40, child: Text('bar')),
  );
}

class TestCoordinator extends Coordinator<AppRoute> {
  TestCoordinator({required this.isolateRepaints});
  final bool isolateRepaints;

  late final IndexedStackPath<AppRoute> tabs = IndexedStackPath.createWith(
    coordinator: this,
    label: 'tabs',
    isolateRepaints: isolateRepaints,
    [Tab('a', animates: true), Tab('b'), Tab('c')],
  )..bindLayout(TabsLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, tabs];

  @override
  AppRoute parseRouteFromUri(Uri uri) => Tab('a', animates: true);
}

/// Render objects repainted in one frame of the spinner's animation.
Future<int> repaintsPerFrame(
  WidgetTester tester, {
  required bool isolate,
}) async {
  final c = TestCoordinator(isolateRepaints: isolate);
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  // Let the tree settle so what is counted below is the animation and nothing
  // else. `pumpAndSettle` would never return — the spinner repeats forever.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }

  var painted = 0;
  debugOnProfilePaint = (_) => painted++;
  await tester.pump(const Duration(milliseconds: 16));
  debugOnProfilePaint = null;
  return painted;
}

void main() {
  testWidgets('an animating tab does not repaint the shell around it', (
    tester,
  ) async {
    final shared = await repaintsPerFrame(tester, isolate: false);
    final isolated = await repaintsPerFrame(tester, isolate: true);

    expect(
      isolated,
      lessThan(shared),
      reason:
          'with one layer for the lot, the spinner drags the tab bar, the '
          'scaffold and both idle tabs into every frame',
    );
  });

  testWidgets('and the boundary is only there when it is asked for', (
    tester,
  ) async {
    // Counted rather than asserted outright: the framework puts boundaries of
    // its own above every tab, so what proves the flag did something is one
    // more of them over the tab's own content.
    Future<int> boundariesAbove(String tab, {required bool isolate}) async {
      final c = TestCoordinator(isolateRepaints: isolate);
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pump();
      return find
          .ancestor(
            of: find.text(tab, skipOffstage: false),
            matching: find.byType(RepaintBoundary, skipOffstage: false),
          )
          .evaluate()
          .length;
    }

    expect(
      await boundariesAbove('tab-b', isolate: true),
      await boundariesAbove('tab-b', isolate: false) + 1,
    );
  });
}
