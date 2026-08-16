import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/shits.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/scroll/link.dart';
import 'package:shits/src/scroll/position.dart';

import '../fixtures/devices.dart';
import 'harness.dart';

// ============================================================================
// `Panel` is five obligations and one lifetime, and this file is one group per
// obligation that nothing below the widget layer could have discharged.
//
//   1. The clock. `PanelModel` owns no `TickerProvider` — that is the layering
//      rule, and it is what keeps every test under `test/model/` a plain
//      `test` — so something has to advance it, exactly once per frame, by a
//      frame delta.
//   2. The box. A panel's viewport is its own constraints and not the window,
//      and the model is constructed before either is known.
//   3. Adoption. A rebuild carries a whole configuration, and almost every
//      rebuild carries an identical one.
//   4. The scroll layer, installed here rather than by the app.
//   5. Teardown, in the one order that does not tick into a disposed model.
//
// The position it publishes is `scope_test.dart`; the bar and the keyboard are
// `content_scaffold_test.dart` and `panel_media_query_test.dart`; the claim
// that a lazy list gets the panel's *visible* extent is
// `lazy_viewport_test.dart`.
// ============================================================================

void main() {
  useIPhone17Pro();

  group('the box a panel is measured in', () {
    testWidgets('is its own constraints, not the window', (tester) async {
      // The panel is 100pt short of the window, so `.full` is
      // 774 - 62 - 34 = 678 and its frame is 678 + 34 = 712. Measured against
      // the window it would be 812 — and the window is what `MediaQuery.sizeOf`
      // answers, which is what the model has to be *constructed* from, because
      // a `PanelModel` needs a `PanelLayout` and `initState` has no constraints
      // to build one out of.
      //
      // So this is the test that the provisional layout never reaches the
      // screen: the model opens at a *detent* rather than at a height, its
      // first correction is `hold`, and the first `performLayout` resolves that
      // detent against the real baseline before anything is painted. A panel
      // that had recorded its opening height instead would sit at 812 inside a
      // 774pt box, with 38pt of it above its own top edge.
      await tester.pumpWidget(
        onIPhone17Pro(
          Padding(
            padding: const EdgeInsets.only(top: 100),
            child: Panel(
              detents: const DetentSet([Detent.full]),
              child: shortList(),
            ),
          ),
        ),
      );

      expect(extentIn(tester), closeTo(712.0, 1e-9));
    });

    testWidgets('and the whole window when nothing shrinks it', (tester) async {
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: longList(),
          ),
        ),
      );

      // 469.68, and not 435.68 (the detent *value*, before `frameOf`), 389
      // (half the baseline), 437 (half the viewport) or 778 (the baseline).
      expect(extentIn(tester), closeTo(kMediumFrame, 1e-9));
    });
  });

  group('the scroll layer, installed by the panel', () {
    testWidgets('captures a bare ListView with no wrapper', (tester) async {
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: longList(),
          ),
        ),
      );

      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position,
        isA<PanelScrollPosition>(),
        reason:
            'the list did not take the panel\'s controller, so nothing it does '
            'can reach the panel',
      );

      // And it arbitrates rather than merely being attached. 60pt up from a
      // list at its top, below the largest detent, is S1: the panel's whole
      // share and none of the list's.
      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();

      expect(extentIn(tester), closeTo(kMediumFrame + 60, 1e-9));
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        0,
        reason: 'the panel had room, so the list is not what moved',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('under a policy the widget names', (tester) async {
      // `scrollsFirst` says the panel is moved by its handle, its background or
      // code, and never by a list. A `Panel` that built its link once with the
      // constructor defaults and never looked at its arguments again passes
      // every other test in this file and fails this one.
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            scrollPolicy: PanelScrollPolicy.scrollsFirst,
            child: longList(),
          ),
        ),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();

      expect(extentIn(tester), closeTo(kMediumFrame, 1e-9));
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        closeTo(60, 1e-9),
        reason: 'the list should have taken the whole delta',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('and a policy change does not replace the link', (
      tester,
    ) async {
      // The three policies are mutable fields on `PanelScrollLink` precisely so
      // that this rebuild is an assignment. A `Panel` that recreated the link
      // instead would drop the position registry — the thing the escape
      // detector and `absorb` both compare against — and detach every list in
      // the panel, mid-gesture, because a placement changed.
      Widget build(PanelScrollPolicy policy) => onIPhone17Pro(
        Panel(
          detents: kPeekSet,
          initialDetent: Detent.medium,
          scrollPolicy: policy,
          child: longList(),
        ),
      );

      await tester.pumpWidget(build(PanelScrollPolicy.resizesFromEdge));
      final PanelScrollLink link =
          (tester.state<ScrollableState>(find.byType(Scrollable)).position
                  as PanelScrollPosition)
              .link;

      await tester.pumpWidget(build(PanelScrollPolicy.scrollsFirst));

      expect(
        identical(
          (tester.state<ScrollableState>(find.byType(Scrollable)).position
                  as PanelScrollPosition)
              .link,
          link,
        ),
        isTrue,
        reason: 'the link was recreated for a policy change',
      );
      expect(link.scrollPolicy, PanelScrollPolicy.scrollsFirst);
    });
  });

  group('the clock a self-driven motion runs on', () {
    testWidgets('is not running while the panel is parked', (tester) async {
      // The instrument, checked before it is trusted. Every count below is read
      // against this zero.
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: longList(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      expect(modelIn(tester).activity, isA<IdlePanelActivity>());
    });

    testWidgets('is one ticker for one settle, not two', (tester) async {
      // **This is the test that fails while `PanelScrollAttachment` still holds
      // a ticker of its own.** Its doc says why it has one — DESIGN.md gives it
      // to `widgets/panel.dart`, which did not exist — and this file is that
      // file. A panel installs the attachment, so two tickers with the same gate
      // both start, `PanelModel.tick` is called twice a frame, and every settle
      // runs at double the speed it was asked for while reporting the duration
      // it was asked for. Falsification criterion 4 is the same claim from the
      // fling's end: one simulation, one ticker.
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            controller: controller,
            child: longList(),
          ),
        ),
      );

      controller.animateTo(Detent.full);
      await tester.pump();

      expect(SchedulerBinding.instance.transientCallbackCount, 1);
      await tester.pumpAndSettle();
    });

    testWidgets('advances the model by a frame delta, once per frame', (
      tester,
    ) async {
      // Measured against a model that is not in a tree and is ticked by hand:
      // the same config, the same layout, the same spring, the same tolerance.
      // Two implementations of the same arithmetic over the same doubles agree
      // exactly, so any disagreement is the *clock* — a second ticker doubling
      // the delta, or `Ticker`'s elapsed-since-start handed over as though it
      // were a delta, which makes the clock grow as the square of the frame
      // count.
      //
      // A duration-based assertion cannot tell those apart: a spring is not
      // done at half its duration whether it has been ticked once or twice per
      // frame. The trajectory can.
      const motion = PanelMotion.smooth(duration: Duration(milliseconds: 500));
      const config = PanelConfig(
        detents: kPeekSet,
        initialDetent: Detent.medium,
        motion: motion,
      );

      final controller = PanelController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: config.detents,
            initialDetent: config.initialDetent,
            motion: config.motion,
            controller: controller,
            child: longList(),
          ),
        ),
      );

      final reference = PanelModel(
        config: config,
        layout: kIPhone17Pro.layout(),
      );
      addTearDown(reference.dispose);

      controller.animateTo(Detent.full);
      reference.animateTo(Detent.full);

      // `Ticker` reports elapsed-since-start, so its first callback is a delta
      // of zero and moves nothing. The reference is not ticked for it.
      await tester.pump();
      expect(extentIn(tester), closeTo(kMediumFrame, 1e-9));

      // Ten frames, all of them inside the spring's own duration, so neither
      // model has parked and the comparison is of two live simulations.
      for (var frame = 1; frame <= 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        reference.tick(const Duration(milliseconds: 16));
        expect(
          extentIn(tester),
          closeTo(reference.extent.px, 1e-6),
          reason: 'frame $frame of a 500ms settle',
        );
      }

      expect(
        extentIn(tester),
        greaterThan(kMediumFrame),
        reason:
            'a comparison of two panels that both never moved is not a test',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('stops once the panel has parked', (tester) async {
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            controller: controller,
            child: longList(),
          ),
        ),
      );

      controller.animateTo(Detent.full);
      await tester.pumpAndSettle();

      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      expect(modelIn(tester).activity, isA<IdlePanelActivity>());
      expect(extentIn(tester), closeTo(kFullFrame, 0.5));
    });

    testWidgets('and does not run for a fling that a list is driving', (
      tester,
    ) async {
      // A `ScrollDrivenActivity` is already being advanced by
      // `FusedBallisticActivity`, on the `Scrollable`'s own vsync. The gate here
      // is the branch of the activity hierarchy rather than a flag, so a leaf
      // added later cannot land on the wrong side of it — and "one fling, one
      // ticker" stays true.
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: longList(),
          ),
        ),
      );

      await tester.fling(find.byType(Scrollable), const Offset(0, -60), 800);
      await tester.pump();

      expect(modelIn(tester).activity, isA<ScrollDrivenActivity>());
      expect(SchedulerBinding.instance.transientCallbackCount, 1);
      await tester.pumpAndSettle();
    });
  });

  group('adopting a rebuild', () {
    testWidgets('an equal detent set is not a set change', (tester) async {
      // The commonest event in the life of a panel: an app rebuilds and hands
      // over a configuration equal to the one it handed over last frame. G10
      // says a *set* change snaps, and a set written inline in a `build` is a
      // fresh object every time — so without value equality every rebuild would
      // re-resolve the detents and re-snap the panel, which is G10 read from the
      // wrong end.
      Widget build() => onIPhone17Pro(
        Panel(
          // Written out here rather than hoisted to a const, because a shared
          // const would be identical and would prove nothing about equality.
          detents: DetentSet([
            const Detent.height(DetentValue(180)),
            Detent.medium,
            Detent.full,
          ]),
          initialDetent: Detent.medium,
          child: longList(),
        ),
      );

      await tester.pumpWidget(build());
      final model = modelIn(tester);
      final activity = model.activity;
      final extent = model.extent;

      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(build());
      }

      expect(
        identical(modelIn(tester), model),
        isTrue,
        reason: 'the model was recreated by a rebuild that changed nothing',
      );
      expect(modelIn(tester).extent, extent);
      expect(
        identical(modelIn(tester).activity, activity),
        isTrue,
        reason: 'an equal config re-snapped the panel',
      );
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    });

    testWidgets('a changed set settles to the nearest surviving stop', (
      tester,
    ) async {
      // The replacement set is authored **descending** and its stops are chosen
      // so that "nearest" is not also "smallest", "largest", "first" or "last":
      // from 469.68 the frames 812, 534 and 214 are 342.32, 64.32 and 255.68
      // away, so only an implementation that measured lands on 534.
      Widget build(DetentSet detents) => onIPhone17Pro(
        Panel(
          detents: detents,
          initialDetent: Detent.medium,
          child: longList(),
        ),
      );

      await tester.pumpWidget(build(kPeekSet));
      expect(extentIn(tester), closeTo(kMediumFrame, 1e-9));

      await tester.pumpWidget(
        build(
          const DetentSet([
            Detent.full,
            Detent.height(DetentValue(500)),
            Detent.height(DetentValue(180)),
          ]),
        ),
      );

      expect(
        modelIn(tester).activity,
        isA<SettlingPanelActivity>(),
        reason: 'the set changed under the panel and it did not re-target',
      );
      expect(
        extentIn(tester),
        closeTo(kMediumFrame, 1e-9),
        reason: 'a set change re-targets the panel; it does not teleport it',
      );

      await tester.pumpAndSettle();
      expect(extentIn(tester), closeTo(534.0, 0.5));
    });

    testWidgets('and the band resistance a panel defaults to is the config\'s', (
      tester,
    ) async {
      // A constant written in two files with nothing comparing them is a
      // constant that will disagree. `Panel` cannot name `PanelConfig`'s,
      // because a constructor default has to be a constant expression and that
      // one is written inline, so this is the comparison instead.
      expect(
        kPanelBandResistance,
        const PanelConfig(detents: kPeekSet).bandResistance,
      );
    });
  });

  group('a controller swapped under a live panel', () {
    testWidgets('changes hands, and the panel it left goes quiet', (
      tester,
    ) async {
      // Both halves, because each has a wrong implementation that passes the
      // other. One that attached the new controller without detaching the old
      // leaves two handles reporting one panel, and which of them an app hears
      // from depends on which rebuilt last; one that detached without
      // attaching leaves the app holding a handle that throws.
      final first = PanelController();
      final second = PanelController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      // Built once and handed to both trees, so the only thing that can rebuild
      // it is the inherited dependency it took. A fresh closure per pump would
      // pick up the new handle whether or not the scope announced it, which is
      // the assertion answering itself.
      late PanelController fromTheContent;
      final content = Builder(
        builder: (context) {
          fromTheContent = PanelScope.of(context);
          return longList();
        },
      );
      Widget build(PanelController controller) => onIPhone17Pro(
        Panel(
          detents: kPeekSet,
          initialDetent: Detent.medium,
          controller: controller,
          child: content,
        ),
      );

      await tester.pumpWidget(build(first));
      final model = modelIn(tester);
      expect(first.isAttached, isTrue);
      expect(identical(fromTheContent, first), isTrue);

      await tester.pumpWidget(build(second));

      expect(
        identical(fromTheContent, second),
        isTrue,
        reason:
            'content that asked for the panel\'s handle is still holding the '
            'one the app took away',
      );

      expect(
        identical(modelIn(tester), model),
        isTrue,
        reason: 'swapping the handle rebuilt the panel behind it',
      );
      expect(first.isAttached, isFalse);
      expect(() => first.animateTo(Detent.full), throwsFlutterError);
      expect(second.isAttached, isTrue);
      expect(second.value!.extent.px, closeTo(kMediumFrame, 1e-9));

      // And it drives, rather than merely reporting: a controller attached to
      // a model it cannot move would satisfy every assertion above.
      second.animateTo(Detent.full);
      await tester.pumpAndSettle();
      expect(extentIn(tester), closeTo(kFullFrame, 0.5));
    });

    testWidgets('and the one the panel made goes with it', (tester) async {
      // The other side of `ScrollController`'s division, and the side nothing
      // could see from outside until now: a panel with no controller makes
      // one, and an app that later supplies its own leaves that one with
      // nothing holding it. The content is what can name it — a panel publishes
      // its handle to its own child whether the app has one or not, which is
      // the whole point of `PanelScope.of`.
      // Every handle the content has been given, in order — and it is given a
      // second one, because swapping the panel's controller is exactly the
      // event `PanelScope.of` announces. The first is the one the panel made.
      final seen = <PanelController>[];
      final content = Builder(
        builder: (context) {
          seen.add(PanelScope.of(context));
          return longList();
        },
      );
      final supplied = PanelController();
      addTearDown(supplied.dispose);

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: content,
          ),
        ),
      );
      expect(seen.single.isAttached, isTrue);
      final made = seen.single;

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            controller: supplied,
            child: content,
          ),
        ),
      );

      expect(
        () => made.addListener(() {}),
        throwsFlutterError,
        reason:
            'the panel made that controller, replaced it, and left it alive '
            'listening to a model nothing else can reach',
      );
      expect(supplied.isAttached, isTrue);
      expect(supplied.value!.extent.px, closeTo(kMediumFrame, 1e-9));
    });
  });

  group('teardown', () {
    testWidgets('leaves nothing running when the panel goes mid-settle', (
      tester,
    ) async {
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            controller: controller,
            child: longList(),
          ),
        ),
      );

      controller.animateTo(Detent.full);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      await tester.pumpWidget(onIPhone17Pro(const SizedBox.shrink()));

      expect(tester.takeException(), isNull);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      expect(
        controller.isAttached,
        isFalse,
        reason:
            'a detached controller still reporting a disposed panel is a '
            'use-after-free waiting for the next animateTo',
      );
    });

    testWidgets('and does not dispose a controller the app made', (
      tester,
    ) async {
      // `ScrollController`'s division: what the app made, the app disposes.
      // Getting it the other way round throws from the app's own `dispose`,
      // one frame after the panel left, with nothing naming the panel.
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(detents: kPeekSet, controller: controller, child: shortList()),
        ),
      );
      await tester.pumpWidget(onIPhone17Pro(const SizedBox.shrink()));

      // A disposed `ChangeNotifier` throws from `addListener`; a live one does
      // not. Asked this way round because there is no public `isDisposed`, and
      // because adding a listener is what a rebuilt panel would do next.
      expect(() => controller.addListener(() {}), returnsNormally);
    });
  });
}
