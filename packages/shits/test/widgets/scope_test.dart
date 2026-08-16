import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/shits.dart';

import '../fixtures/devices.dart';
import 'harness.dart';

// ============================================================================
// The panel publishes its **position**, continuously, and not its resting
// detent. DESIGN.md A6.4 reaches that from two directions — a `.conditional`
// bottom bar re-evaluates its predicate "whenever the metrics change", and
// coverage row #21 (`offset_driven_animation`) is built on nothing else — and
// two rows needing it is what makes it a requirement.
//
// A requirement with a cost, so half this file is about who pays it. There are
// two lookups over one controller: `PanelScope.of` depends on the controller's
// identity and `PanelScope.metricsOf` depends on the position. An
// implementation with one scope for both satisfies every assertion about
// *values* below and fails the one about builds — which is the whole reason
// that test is here.
// ============================================================================

void main() {
  useIPhone17Pro();

  group('the position, published', () {
    testWidgets('is the panel\'s own from the first build', (tester) async {
      // Not one frame later. The model is constructed before the content is
      // built, so there is a position to publish from the start — and content
      // laid out against a metrics of null, or of zero, is the blank first
      // frame this package is supposed not to have.
      final seen = <double>[];

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: Builder(
              builder: (context) {
                seen.add(PanelScope.metricsOf(context).extent.px);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );

      expect(seen.first, closeTo(kMediumFrame, 1e-9));
    });

    testWidgets('changes on every frame of a settle, not twice', (
      tester,
    ) async {
      // The distinction the whole file exists for. A panel that published only
      // its resting detent would produce two readings — the one it left and the
      // one it arrived at — and both of them would be right.
      final controller = PanelController();
      addTearDown(controller.dispose);
      final seen = <double>[];
      controller.addListener(() => seen.add(controller.value!.extent.px));

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            controller: controller,
            child: const SizedBox.expand(),
          ),
        ),
      );

      seen.clear();
      controller.animateTo(Detent.full);
      // At a frame, and not at `pumpAndSettle`'s 100ms default. A 500ms spring
      // settles in ~550ms, so the default step turns "~30 frames" into 7 — and
      // 7 is a number a panel that published twice a settle could also reach by
      // being pumped seven times. Measured at 16ms it is 34 readings against 2,
      // which is the margin this test is claiming.
      await tester.pumpAndSettle(const Duration(milliseconds: 16));

      expect(seen.length, greaterThan(10), reason: 'a settle is ~30 frames');
      expect(
        seen.toSet().length,
        greaterThan(10),
        reason: 'the same reading repeated is not a position',
      );
      expect(
        seen,
        orderedEquals(List<double>.of(seen)..sort()),
        reason: 'a settle from 469.68 to 812 is monotone',
      );
      expect(seen.last, closeTo(kFullFrame, 0.5));
    });

    testWidgets('and only what asked for it is rebuilt', (tester) async {
      // `PanelScope.of` takes a dependency on the controller's identity;
      // `PanelScope.metricsOf` takes one on the position. One inherited widget
      // carrying both would make every consumer of the controller a consumer of
      // the position, and a content scaffold whose body wanted a `settleTo`
      // would rebuild its whole subtree sixty times a second.
      final controller = PanelController();
      addTearDown(controller.dispose);
      final wantsController = Counter();
      final wantsPosition = Counter();

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            controller: controller,
            child: Column(
              children: [
                counting(wantsController, (context) {
                  PanelScope.of(context);
                  return const SizedBox(height: 10);
                }),
                counting(wantsPosition, (context) {
                  PanelScope.metricsOf(context);
                  return const SizedBox(height: 10);
                }),
              ],
            ),
          ),
        ),
      );

      final before = wantsController.value;
      controller.animateTo(Detent.full);
      // 16ms and not `pumpAndSettle`'s 100ms default, for the reason the test
      // above gives: the default turns a 500ms settle into 7 frames, and the
      // lower bound below is a count of frames.
      await tester.pumpAndSettle(const Duration(milliseconds: 16));

      expect(
        wantsController.value,
        before,
        reason: 'a moving panel rebuilt a widget that only wanted its handle',
      );
      expect(wantsPosition.value, greaterThan(before + 10));
    });

    testWidgets('and a panel corrected by its own layout says so next frame', (
      tester,
    ) async {
      // **A panel commits its layout from inside a layout pass.**
      // `RenderPanelViewport.performLayout` lays the child out and then calls
      // `PanelModel.applyLayout`, whose job is to commit and tell people — the
      // render layer says so in its own doc. So the notification can arrive
      // while the framework is building, laying out and painting, and a
      // consumer of the position marked dirty from there is
      // `WidgetsBinding._handleBuildScheduled`'s "Build scheduled during
      // frame". A panel 100pt short of the window is the smallest case that
      // produces it: the model is constructed from the window and the first
      // pass corrects it.
      //
      // Both halves are asserted, because each alone is satisfiable by a
      // broken panel. A controller that never announced at all would not throw
      // and would leave the content describing a 812pt panel inside a 712pt
      // box; one that announced from inside the pass would be right about the
      // number and would throw.
      final seen = <double>[];
      await tester.pumpWidget(
        onIPhone17Pro(
          Padding(
            padding: const EdgeInsets.only(top: 100),
            child: Panel(
              detents: const DetentSet([Detent.full]),
              child: Builder(
                builder: (context) {
                  seen.add(PanelScope.metricsOf(context).extent.px);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(extentIn(tester), closeTo(712.0, 1e-9));
      expect(
        seen.first,
        closeTo(kFullFrame, 1e-9),
        reason:
            'the first build is before the first layout, so it is the '
            'provisional window-sized answer — that is the frame this test is '
            'about',
      );

      await tester.pump();

      expect(
        seen.last,
        closeTo(712.0, 1e-9),
        reason:
            'the panel corrected itself at layout and never told its content, '
            'which is now describing a sheet 100pt taller than the box it is '
            'in',
      );
    });
  });

  group('the controller', () {
    testWidgets('reports nothing until it has a panel', (tester) async {
      final controller = PanelController();
      addTearDown(controller.dispose);

      expect(controller.value, isNull);
      expect(controller.isAttached, isFalse);

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            controller: controller,
            child: const SizedBox.expand(),
          ),
        ),
      );

      expect(controller.isAttached, isTrue);
      expect(controller.value!.extent.px, closeTo(kMediumFrame, 1e-9));
    });

    testWidgets('moves the panel to a detent it is named', (tester) async {
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            controller: controller,
            child: const SizedBox.expand(),
          ),
        ),
      );

      controller.animateTo(Detent.height(const DetentValue(180)));
      await tester.pumpAndSettle();
      expect(extentIn(tester), closeTo(kPeekFrame, 0.5));

      controller.settleTo(Detent.full);
      await tester.pumpAndSettle();
      expect(extentIn(tester), closeTo(kFullFrame, 0.5));
    });

    testWidgets('and refuses to move a panel it has not got', (tester) async {
      // An `animateTo` that silently did nothing is the failure this package is
      // written against one level up, in the scroll layer's escape report. The
      // same rule applies to its own handle.
      final controller = PanelController();
      addTearDown(controller.dispose);

      expect(() => controller.animateTo(Detent.full), throwsFlutterError);
    });
  });

  group('reached from the content', () {
    testWidgets('throws outside a panel, naming what is missing', (
      tester,
    ) async {
      late BuildContext outside;
      await tester.pumpWidget(
        onIPhone17Pro(
          Builder(
            builder: (context) {
              outside = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );

      expect(() => PanelScope.of(outside), throwsFlutterError);
      expect(() => PanelScope.metricsOf(outside), throwsFlutterError);
      expect(PanelScope.maybeOf(outside), isNull);
      expect(PanelScope.maybeMetricsOf(outside), isNull);
    });
  });

  group('the derived scalars, each with its divisor named', () {
    test('openProgress normalises against the travel', () {
      // 214 -> 0, 812 -> 1, and 469.68 -> 255.68 / 598 = 0.42756. The two
      // plausible wrong divisors land elsewhere: against `detents.max` the
      // middle stop reads 0.578, against the viewport 0.537. Only the travel
      // gives 0.428, and only the travel puts the smallest stop at zero.
      expect(metricsAt(extent: kPeekFrame).openProgress, 0);
      expect(metricsAt(extent: kFullFrame).openProgress, 1);
      expect(
        metricsAt(extent: kMediumFrame).openProgress,
        closeTo(0.4275585, 1e-6),
      );
    });

    test('and stays 1.0 in the rubber band above the largest stop', () {
      // A drag past `.full` puts the panel above its own ceiling, which is the
      // one state in this slice where the numerator exceeds the divisor: 40pt
      // of band is 638 over a travel of 598, or 1.067. Unclamped that reaches a
      // `Tween` as an overshoot and an `Opacity` as an assertion, and the panel
      // is doing nothing unusual — it is being dragged.
      expect(metricsAt(extent: kFullFrame + 40).openProgress, 1.0);
    });

    test('and answers 1.0 rather than NaN when there is no travel', () {
      // A one-detent set is not a degenerate case: it is what `Detent.full`
      // alone means, and A4 says a `.medium`-only set is legal too. `0 / 0` here
      // reaches a `Tween`, an `Opacity` and a `Transform` before anything
      // notices — a NaN opacity paints nothing and reports no error.
      final single = const DetentSet([
        Detent.full,
      ]).resolve(kIPhone17Pro.panelBaseline());

      expect(metricsAt(extent: kFullFrame, detents: single).openProgress, 1.0);
    });

    test('presentationProgress is measured from where the placement rests', () {
      // A2, and it is the reason the resting offset is carried rather than
      // assumed to be zero. A 300pt dialog fully present in an 874pt viewport
      // rests at (874 - 300) / 2 = 287; measured from zero it reports 0.043 —
      // a barrier 4% opaque behind a finished dialog and a route simulation
      // seeded from 4%, which is the defect this document rejects design B for.
      expect(metricsAt(extent: kMediumFrame).presentationProgress, 1.0);
      expect(
        metricsAt(
          extent: 300,
          edgeOffset: 287,
          restingOffset: 287,
        ).presentationProgress,
        1.0,
      );
      // And half a panel's own span past its rest is half gone.
      expect(
        metricsAt(extent: 400, edgeOffset: 200).presentationProgress,
        closeTo(0.5, 1e-9),
      );
    });

    test('nearestDetent measures rather than picking an end', () {
      // 400 is 186 above the peek's frame and 69.68 below `.medium`'s, so the
      // answer is the middle stop — which is neither the smallest, the largest,
      // the first authored nor the last. A panel parked exactly on a detent
      // could not tell those five implementations apart.
      expect(metricsAt(extent: 400).nearestDetent, Detent.medium);
      expect(
        metricsAt(extent: 260).nearestDetent,
        const Detent.height(DetentValue(180)),
      );
    });

    test('viewportSize puts the span on the axis the panel resizes along', () {
      // A baseline stores its two measurements **by axis** — a span and a
      // cross — so putting them back into screen order is a switch, and a
      // switch with two arms that agree on the case you happen to test is a
      // switch nobody has tested. A bottom sheet's viewport is 402x874 whether
      // the pair is swapped or not, because `crossSpan` is the width and
      // `viewportSpan` is the height. A drawer's is the row that tells them
      // apart: 402x874 correct, 874x402 swapped.
      PanelMetrics along(PanelAnchor anchor) => PanelMetrics(
        extent: const Extent(300),
        edgeOffset: EdgeOffset.zero,
        restingOffset: EdgeOffset.zero,
        // `.full` alone: `Detent.medium` is a vertical measurement and refuses
        // a horizontal baseline, which is the geometry layer being right.
        detents: const DetentSet([
          Detent.full,
        ]).resolve(kIPhone17Pro.panelBaseline(anchor: anchor)),
        layout: kIPhone17Pro.layout(anchor: anchor),
        anchor: anchor,
      );

      expect(along(PanelAnchor.bottom).viewportSize, kIPhone17Pro.size);
      expect(along(PanelAnchor.leading).viewportSize, kIPhone17Pro.size);
    });

    test('and two readings of one panel are equal, field by field', () {
      // The equality is load-bearing in both directions: it is what lets a
      // consumer hold last frame's metrics and compare, and it is what keeps a
      // `MediaQuery` derived from these from notifying dependents on a frame
      // where nothing they read moved.
      //
      // One field at a time, because [extent] is the only field the rest of
      // this suite varies — an `==` that compared it alone would satisfy every
      // other assertion in the file.
      final base = metricsAt(extent: kMediumFrame);
      expect(base, metricsAt(extent: kMediumFrame));
      expect(base.hashCode, metricsAt(extent: kMediumFrame).hashCode);

      expect(base, isNot(metricsAt(extent: kFullFrame)));
      expect(base, isNot(metricsAt(extent: kMediumFrame, edgeOffset: 90)));
      expect(base, isNot(metricsAt(extent: kMediumFrame, restingOffset: 90)));
      expect(
        base,
        isNot(metricsAt(extent: kMediumFrame, viewInsets: kKeyboard)),
        reason: 'the keyboard is in the layout, and the layout is a field',
      );
      expect(
        base,
        isNot(
          metricsAt(
            extent: kMediumFrame,
            detents: const DetentSet([
              Detent.full,
            ]).resolve(kIPhone17Pro.panelBaseline()),
          ),
        ),
      );
      expect(
        base,
        isNot(
          PanelMetrics(
            extent: base.extent,
            edgeOffset: base.edgeOffset,
            restingOffset: base.restingOffset,
            detents: base.detents,
            layout: base.layout,
            anchor: PanelAnchor.top,
          ),
        ),
        reason:
            'two panels of the same height growing opposite ways are not the '
            'same panel — their rects do not even overlap',
      );

      // And it can say what it is. A `toString` nothing runs is a failure
      // message nobody has read, and this type's whole job when something goes
      // wrong is to be the thing quoted in it.
      expect(
        base.toString(),
        allOf(contains('469.68'), contains('bottom')),
        reason: 'a metrics that cannot describe itself names nothing',
      );
    });

    testWidgets('and the rect is the one the panel was laid out at', (
      tester,
    ) async {
      // One function, called twice. A second derivation here — `0, 0, cross,
      // extent`, say — is plausible, finite and wrong by the whole viewport
      // offset, and nothing downstream could tell.
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: const SizedBox.expand(),
          ),
        ),
      );

      final metrics = boxIn(tester).model;
      expect(
        PanelMetrics(
          extent: metrics.extent,
          edgeOffset: metrics.edgeOffset,
          restingOffset: metrics.restingOffset,
          detents: metrics.detents,
          layout: metrics.layout,
          anchor: PanelAnchor.bottom,
        ).rect,
        boxIn(tester).panelRect,
      );
    });
  });
}
