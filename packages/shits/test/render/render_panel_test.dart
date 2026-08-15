import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/render/render_panel.dart';

import '../fixtures/devices.dart';
import 'harness.dart';

// ============================================================================
// `RenderPanelViewport` is four claims, and this file is one group per claim.
//
//   1. It is a relayout boundary, so a per-frame markNeedsLayout never dirties
//      the app tree — and its child is one, so content-internal layout never
//      dirties it. Two separate facts with two separate causes, held apart.
//   2. The extent comes from the model, once per pass, through dryApplyLayout
//      to size and applyLayout to commit — in that order.
//   3. Content is measured by dry layout, never by intrinsics.
//   4. One child layout per frame. Counted, not hoped for.
//
// `boundary_premise_test.dart` next door pins the framework rule claim 1 rests
// on, and — more usefully — proves that the fixture used here tells a
// sizedByParent panel apart from one that is not. Every boundary assertion below
// runs on a host that passes loose constraints and reads the panel's size, which
// is the only configuration where the two answers differ.
//
// Numbers are the iPhone 17 Pro throughout, because its four plausible readings
// are far apart: `.medium` is a detent value of 435.68 and a frame of 469.68,
// against 389 for half the baseline, 437 for half the viewport and 778 for the
// baseline itself. An assertion that lands on 469.68 cannot also be satisfied by
// a panel that forgot `frameOf`, or one that resolved against the raw viewport.
// ============================================================================

const _peek = Detent.height(DetentValue(180));
const _sheet = DetentSet([_peek, Detent.medium, Detent.full]);
const _config = PanelConfig(detents: _sheet, initialDetent: Detent.medium);

/// A panel opened at `.medium` on an iPhone 17 Pro.
PanelModel openAtMedium() =>
    PanelModel(config: _config, layout: kIPhone17Pro.layout());

/// The rig, with its model and its teardown already wired.
PanelRig rigAtMedium({
  PanelMedia? media,
  PanelAnchor anchor = PanelAnchor.bottom,
  EdgeAttachment attachment = EdgeAttachment.edgeAttached,
  PanelSizing sizing = PanelSizing.resize,
  bool measuresContent = false,
  bool withChild = true,
  BoxConstraints? childConstraints,
}) {
  final model = openAtMedium();
  addTearDown(model.dispose);
  final rig = PanelRig(
    model: model,
    media: media,
    anchor: anchor,
    attachment: attachment,
    sizing: sizing,
    measuresContent: measuresContent,
    withChild: withChild,
    childConstraints: childConstraints,
  );
  addTearDown(rig.dispose);
  return rig;
}

/// `.medium` on the 17 Pro with the panel floating clear of the bottom edge.
///
/// 0.56 × 778 with no attachment padding added — 435.68, which is 34pt short of
/// [mediumFrameOnPro] and is the *right* answer for a floating panel. It is
/// also, exactly, the wrong answer for an attached one, which is what makes the
/// pair discriminating in both directions.
final double mediumFloatingOnPro = 0.56 * kIPhone17Pro.baseline;

/// A [PaintingContext] that records where children were painted instead of
/// painting them.
///
/// A real one needs a live layer tree and a binding; this layer's tests have
/// neither by design, and the only thing worth asserting about [paint] is the
/// offset it hands `paintChild`.
final class _RecordingContext extends PaintingContext {
  _RecordingContext() : super(ContainerLayer(), Rect.largest);

  /// Every `(child, offset)` this context was asked to paint.
  final List<(RenderObject, Offset)> painted = <(RenderObject, Offset)>[];

  @override
  void paintChild(RenderObject child, Offset offset) =>
      painted.add((child, offset));
}

/// Starts a drag on the panel and returns it, with the counters cleared.
DragPanelActivity beginDrag(PanelRig rig) {
  final drag = DragPanelActivity(from: rig.model.extent);
  rig.model.beginActivity(drag);
  rig.flush();
  rig.content.reset();
  return drag;
}

/// Content that writes to the model from inside its own layout.
///
/// The shape `ScrollPosition.applyContentDimensions` and `correctPixels` have,
/// and the scroll layer is the next slice. Armed once per write so that the pass
/// after the failure is a clean one.
final class _ModelTouchingBox extends CountingBox {
  _ModelTouchingBox(this.model);

  /// The model to write to — the same one the panel is reading.
  final PanelModel model;

  /// The extent to write on the next layout, or null to behave.
  Extent? writeOnLayout;

  @override
  void performLayout() {
    super.performLayout();
    final write = writeOnLayout;
    if (write == null) return;
    writeOnLayout = null;
    model.applyExtent(write);
  }
}

/// Content that cannot decide how long it is.
///
/// Answers [a] and [b] alternately to every dry layout, which is the input
/// DESIGN.md §2.5's oscillation tripwire exists for.
final class _DitheringBox extends CountingBox {
  _DitheringBox({required this.a, required this.b});

  /// The two spans it alternates between.
  final double a;

  /// The second of them.
  final double b;

  bool _flipped = false;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    super.computeDryLayout(constraints);
    _flipped = !_flipped;
    return Size(constraints.maxWidth, _flipped ? a : b);
  }
}

void main() {
  group('1a. the panel is a relayout boundary, so a drag stops at it', () {
    test('the fixture below it is the one that can tell the two apart', () {
      // The premise every assertion in 1a and 1b rests on, asserted rather than
      // described. `_isRelayoutBoundary = !parentUsesSize || sizedByParent ||
      // constraints.isTight || parent == null` (`rendering/object.dart:2847`):
      // a host that dictated the panel's size, or one that did not read it,
      // would make the panel a boundary whatever the panel did, and every
      // assertion under it would pass against an implementation that had never
      // heard of `sizedByParent`. `boundary_premise_test.dart` proves the
      // framework rule; this proves that *this rig's default* is the
      // discriminating configuration, which that file cannot — it builds its own.
      final rig = rigAtMedium();

      expect(
        rig.host.childConstraints.isTight,
        isFalse,
        reason: 'tight constraints alone would make any child a boundary',
      );
      expect(
        rig.host.parentUsesSize,
        isTrue,
        reason: 'and a host that ignored the panel size would too',
      );
    });

    test('a frame of a drag dirties the panel and nothing above it', () {
      final rig = rigAtMedium();
      final drag = beginDrag(rig);

      drag.update(40);

      expect(
        rig.panel.debugNeedsLayout,
        isTrue,
        reason: 'the model moved, so the panel owes a layout',
      );
      expect(
        rig.host.debugNeedsLayout,
        isFalse,
        reason:
            'and the app tree above it owes nothing. The host reads the panel s '
            'size and constrains it loosely, so sizedByParent is the only thing '
            'that can be stopping this — see boundary_premise_test.dart',
      );

      final hostLayouts = rig.host.layouts;
      rig.flush();

      expect(rig.host.layouts, hostLayouts, reason: 'the host did not re-run');
      expect(rig.content.layouts, 1, reason: 'the panel and its child did');
    });

    test('sixty of them still never reach the host', () {
      final rig = rigAtMedium();
      final drag = beginDrag(rig);
      final hostLayouts = rig.host.layouts;

      for (var i = 0; i < 60; i++) {
        drag.update(1);
        rig.flush();
      }

      expect(rig.host.layouts, hostLayouts);
      expect(rig.content.layouts, 60);
    });
  });

  group('1b. the child is a relayout boundary, so content stops at it', () {
    test('content-internal layout does not dirty the panel', () {
      final rig = rigAtMedium();
      rig.content.reset();

      rig.content.markNeedsLayout();

      expect(rig.content.debugNeedsLayout, isTrue);
      expect(
        rig.panel.debugNeedsLayout,
        isFalse,
        reason:
            'a list that gained an item re-lays-out itself; the panel it is in '
            'has not changed height and must not be asked to',
      );

      rig.flush();
      expect(
        rig.content.layouts,
        1,
        reason:
            'and the flush really did lay something out, so the assertion above '
            'is about a boundary rather than about an empty frame',
      );
    });

    test('the constraints handed to the child are tight on both axes', () {
      final rig = rigAtMedium();

      // The behavioural test above is carried today by `parentUsesSize: false`,
      // which makes any child a boundary. This is the assertion that keeps the
      // claim true the day a content detent makes the panel read `child.size`:
      // from then on tightness is the only disjunct left, and
      // `BoxConstraints.isTight` is `hasTightWidth && hasTightHeight`
      // (`rendering/box.dart:377`) — so a constraint tight on the span axis
      // alone, which is what DESIGN.md §2.5's `_tightOnSpanAxis` describes,
      // would not be tight at all.
      expect(rig.content.lastConstraints.hasTightHeight, isTrue);
      expect(
        rig.content.lastConstraints.hasTightWidth,
        isTrue,
        reason:
            'the cross axis is pinned at every detent anyway — that is G8 — so '
            'tightening it costs nothing and buys the boundary',
      );
      expect(rig.content.lastConstraints.isTight, isTrue);
    });

    test('unless the panel measures it, and then it must dirty the panel', () {
      // The documented exception, and the only reason a content detent could
      // ever update. `RenderBox.markNeedsLayout` (`rendering/box.dart:2856`) is
      // `if (_layoutCacheStorage.clear() && parent != null) {
      // markParentNeedsLayout(); return; }` — so once `measureContent` has
      // asked the child for a dry layout, the child's next dirty escalates past
      // the boundary the test above asserts.
      //
      // It is a different budget under a different configuration, and the pair
      // is what says so: without this line the same rig in its other
      // configuration is untested, and `measuresContent` could be a field that
      // only changes what is measured rather than what is invalidated.
      final rig = rigAtMedium(measuresContent: true);
      rig.content.reset();

      rig.content.markNeedsLayout();

      expect(
        rig.panel.debugNeedsLayout,
        isTrue,
        reason:
            'content that grew has to reach the panel, or a Detent.content '
            'resolves against a measurement taken before the growth and never '
            'takes another',
      );
      expect(
        rig.host.debugNeedsLayout,
        isFalse,
        reason: 'and it still stops at the panel — sizedByParent is unchanged',
      );

      rig.flush();
      expect(
        rig.content.dryLayouts,
        1,
        reason: 'the escalated pass re-measured, rather than reusing the cache',
      );
      expect(rig.content.layouts, 1, reason: 'and laid out once, not twice');
    });
  });

  group('2. the extent comes from the model, and the child is laid out at it', () {
    test('a panel opened at .medium lays its child out at 469.68', () {
      final rig = rigAtMedium();
      final span = spanOf(rig.content.lastConstraints);

      expect(span, closeTo(mediumFrameOnPro, 1e-9));

      // The four wrong answers this number is chosen to exclude. Each is a real
      // implementation someone could write and be pleased with.
      expect(
        span,
        isNot(closeTo(0.56 * kIPhone17Pro.baseline, 0.5)),
        reason: 'the detent value, laid out as though it were a frame — A1',
      );
      expect(
        span,
        isNot(closeTo(0.5 * kIPhone17Pro.baseline, 0.5)),
        reason: '0.56 tidied into a half — G4',
      );
      expect(
        span,
        isNot(closeTo(0.56 * kIPhone17Pro.size.height, 0.5)),
        reason:
            'the fraction resolved against the raw viewport — research gap 1',
      );
      expect(
        span,
        isNot(closeTo(kIPhone17Pro.size.height, 0.5)),
        reason: 'the child given the whole box, which is what the panel is',
      );
    });

    test('the cross axis is the viewport width, pinned', () {
      final rig = rigAtMedium();
      expect(rig.content.lastConstraints.maxWidth, kIPhone17Pro.size.width);
    });

    test('parking at another detent lays the child out at that one', () {
      final rig = rigAtMedium();

      rig.model.goIdle(target: Detent.full);
      rig.flush();

      expect(
        spanOf(rig.content.lastConstraints),
        closeTo(fullFrameOnPro, 1e-9),
        reason:
            '.full is the safe span of 778 plus the 34pt it sits above, so the '
            'panel top edge lands on the 62pt view padding exactly — G2, G3 and '
            'G6 only reconcile through frameOf',
      );
    });

    test('a rotation moves the panel to where the detent now is', () {
      final rig = rigAtMedium();

      // The same safe-area geometry on a taller phone, so only the baseline
      // moves: 956 − 62 − 34 = 860, and `.medium` becomes 0.56 × 860 + 34.
      rig.setViewport(kIPhone17ProMax.size);

      final expected = 0.56 * kIPhone17ProMax.baseline + 34;
      expect(spanOf(rig.content.lastConstraints), closeTo(expected, 1e-9));
      expect(
        spanOf(rig.content.lastConstraints),
        isNot(closeTo(mediumFrameOnPro, 0.5)),
        reason: 'a panel that ignored the new layout would still be at 469.68',
      );
      expect(
        spanOf(rig.content.lastConstraints),
        isNot(closeTo(0.56 * kIPhone17ProMax.baseline, 0.5)),
        reason: 'and one that re-resolved without frameOf would be 34pt short',
      );
    });

    test('the child is laid out before the commit notifies', () {
      final rig = rigAtMedium();
      rig.content.reset();

      int? layoutsWhenNotified;
      void listener() => layoutsWhenNotified ??= rig.content.layouts;
      rig.model.addListener(listener);
      addTearDown(() => rig.model.removeListener(listener));

      // A pass that genuinely moves the extent, so the commit has something to
      // announce: the detent changes from .medium to .full inside this frame.
      rig.model.goIdle(target: Detent.full);
      layoutsWhenNotified = null;
      rig.flush();

      expect(
        layoutsWhenNotified,
        isNotNull,
        reason:
            'the commit must notify, or the ordering assertion below is about '
            'an event that never happened',
      );
      expect(
        layoutsWhenNotified,
        1,
        reason:
            'the child was already laid out when applyLayout announced the '
            'move. A panel that committed first would have announced a height '
            'its content had not yet been given',
      );
    });

    test('the commit does not re-dirty the panel it is running inside', () {
      final rig = rigAtMedium();
      rig.content.reset();

      var notifications = 0;
      void listener() => notifications++;
      rig.model.addListener(listener);
      addTearDown(() => rig.model.removeListener(listener));

      rig.model.goIdle(target: Detent.full);
      notifications = 0;
      rig.flush();

      expect(
        notifications,
        greaterThanOrEqualTo(1),
        reason:
            'applyLayout notifies from inside the layout pass — that is its '
            'documented shape, one notification for the whole commit',
      );
      expect(
        rig.panel.debugNeedsLayout,
        isFalse,
        reason:
            'and the panel ignores its own announcement. Answering it with '
            'markNeedsLayout trips _debugCanPerformMutations in debug and '
            're-dirties the panel every frame forever in release',
      );

      final layouts = rig.content.layouts;
      rig.flush();
      expect(rig.content.layouts, layouts, reason: 'nothing was left dirty');
    });

    test('and the rect a listener reads during the commit is this pass\'s', () {
      final rig = rigAtMedium();

      Rect? rectWhenNotified;
      double? extentWhenNotified;
      void listener() {
        rectWhenNotified ??= rig.panel.panelRect;
        extentWhenNotified ??= rig.model.extent.px;
      }

      rig.model.addListener(listener);
      addTearDown(() => rig.model.removeListener(listener));

      rig.model.goIdle(target: Detent.full);
      // `goIdle` notified too, from outside the pass. What is being measured is
      // the notification `applyLayout` makes from *inside* it.
      rectWhenNotified = null;
      extentWhenNotified = null;
      rig.flush();

      expect(
        extentWhenNotified,
        isNotNull,
        reason: 'the commit must notify, or this measures nothing',
      );
      expect(extentWhenNotified, closeTo(fullFrameOnPro, 1e-9));
      expect(
        rectWhenNotified!.height,
        closeTo(fullFrameOnPro, 1e-9),
        reason:
            'panelRect is published before the commit, so the rect and the '
            'extent a listener reads in the same notification describe the same '
            'frame. Published after, this reads 469.68 while the extent beside '
            'it says 812 — and panelRect is public precisely because the '
            'barrier, the handle and the hit-test surfaces are model listeners',
      );
    });

    test('content that moves the model mid-pass is named, not swallowed', () {
      final model = openAtMedium();
      addTearDown(model.dispose);
      final content = _ModelTouchingBox(model);
      final rig = PanelRig(model: model, content: content);
      addTearDown(rig.dispose);

      // A drag, so `freeze` answers `current`: under `hold` the commit
      // re-resolves the detent and heals the divergence before anything can
      // see it, which would make this a test of the correction rather than of
      // the pass.
      final drag = DragPanelActivity(from: model.extent);
      model.beginActivity(drag);
      rig.flush();

      content.writeOnLayout = const Extent(300);
      drag.update(10);

      expect(
        rig.flush,
        throwsA(
          isA<AssertionError>().having(
            (error) => error.toString(),
            'message',
            contains('while the panel was laying the content out'),
          ),
        ),
        reason:
            'the child has been laid out at one height and the model now holds '
            'another, so the pass is about to commit a height its content was '
            'never given. Nothing else detects it: the model asserts that '
            'resolve is a function of its arguments *within one call*, not that '
            'the dry answer and the committed one agree, and child.layout is '
            'between the two calls. What the framework says instead names the '
            'symptom — this box was mutated in its own performLayout — which is '
            'true of the guard rather than of the mistake',
      );

      expect(
        content.layouts,
        greaterThan(0),
        reason: 'and the child really was laid out before the refusal',
      );

      drag.update(10);
      expect(
        rig.panel.debugNeedsLayout,
        isTrue,
        reason:
            'and the panel is still listening. The guard is raised for the '
            'whole pass and lowered in a finally, so a pass that threw does not '
            'leave it standing — a panel deaf to its model for the rest of the '
            'app life is a far quieter failure than the one that set it',
      );
    });

    test('a panel with no child still commits its layout', () {
      final rig = rigAtMedium(withChild: false);

      expect(
        rig.model.layout.baseline.safeSpan.px,
        778,
        reason:
            'the commit is not conditional on there being something to lay '
            'out — a model whose state depended on whether anyone was looking '
            'would answer a different height to the barrier than to the content',
      );
      expect(rig.panel.panelRect.height, closeTo(mediumFrameOnPro, 1e-9));
    });
  });

  group('3. content is measured by dry layout, never by intrinsics', () {
    test('the counter that says so moves when an intrinsic is walked', () {
      // The instrument, calibrated. Every other assertion in this group reads
      // `intrinsics` and expects **zero**, which is exactly the assertion a
      // counter that never counts also satisfies — a mutation sweep deleted the
      // `intrinsics++` in the harness and the whole group stayed green. Its two
      // siblings need no line like this: tests demand non-zero `layouts` and
      // `dryLayouts` elsewhere, so deleting either is caught.
      final rig = rigAtMedium();
      rig.content.reset();

      rig.content.getMinIntrinsicHeight(402);

      expect(
        rig.content.intrinsics,
        1,
        reason:
            'the loudest claim this layer makes — never intrinsics, the route '
            'stupid_simple_sheet takes — is held by this counter, and a counter '
            'nothing requires to move holds nothing',
      );
      expect(rig.content.dryLayouts, 0, reason: 'and it is not a dry layout');
      expect(rig.content.layouts, 0, reason: 'nor a layout');
    });

    test('a panel that measures nothing asks the content nothing', () {
      // Counted from construction and never reset, because `getDryLayout`
      // memoises per `BoxConstraints` and the measure's constraints do not move
      // during a drag — so a probe added to every frame would show up once, on
      // the very first pass, and a counter cleared after that pass would miss
      // it entirely.
      final rig = rigAtMedium();

      expect(rig.content.dryLayouts, 0, reason: 'not even on the first pass');

      final drag = DragPanelActivity(from: rig.model.extent);
      rig.model.beginActivity(drag);
      drag.update(40);
      rig.flush();

      expect(
        rig.content.dryLayouts,
        0,
        reason:
            'no detent in this set is content-sized, so a probe here would be '
            'the second layout per frame this design exists to avoid, bought '
            'back under another name',
      );
      expect(
        rig.content.intrinsics,
        0,
        reason:
            'and nothing walks intrinsics, ever. That is the route '
            'stupid_simple_sheet takes, in a method it named '
            '_illegallyComputeMinIntrinsicHeight',
      );
    });

    test('a measuring panel dry-lays its content out once per pass', () {
      // Counted from construction rather than after a `reset`, because
      // `RenderBox.getDryLayout` memoises per `BoxConstraints`
      // (`rendering/box.dart:1054`, cleared by `markNeedsLayout` at `:1150`).
      // A second call with the same constraints is served from that cache and
      // never reaches `computeDryLayout` — which is the reason DESIGN.md §2.5's
      // own memo, keyed on a `debugLayoutCount` that does not exist, would be a
      // stale cache with no invalidation on top of a correct one.
      final rig = rigAtMedium(measuresContent: true);

      expect(rig.content.dryLayouts, 1, reason: 'one measure for one pass');
      expect(rig.content.layouts, 1, reason: 'and one real layout, not two');
      expect(
        rig.content.lastDryConstraints.hasTightWidth,
        isTrue,
        reason:
            'the cross axis is pinned, so the content is measured in the width '
            'it will actually be laid out in — a span measured against another '
            'width is a measurement of another layout',
      );
      expect(
        rig.content.lastDryConstraints.hasTightHeight,
        isFalse,
        reason: 'and the span is loose, because that is the question',
      );
      expect(
        rig.content.lastDryConstraints.maxHeight,
        closeTo(fullFrameOnPro, 1e-9),
        reason: 'bounded by the largest frame a detent could ask for',
      );
      expect(
        rig.content.intrinsics,
        0,
        reason:
            'getMinIntrinsicHeight on a viewport trips '
            'debugThrowIfNotCheckingIntrinsics and returns 0.0 when the assert '
            'is suppressed — see panel_viewport_test.dart, which proves that on '
            'a real ListView rather than citing it',
      );
    });

    test('measuring offers the largest frame a detent allows', () {
      final rig = rigAtMedium(measuresContent: true);

      expect(
        rig.panel.measureContent(kIPhone17Pro.panelBaseline()).px,
        closeTo(fullFrameOnPro, 1e-9),
        reason:
            'the bound is the frame .full would take — 778 + 34 — derived from '
            'the baseline inside the measurement rather than handed to it, so '
            'the rule cannot drift from the call site',
      );
      expect(
        rig.panel.measureContent(kIPhone17Pro.panelBaseline()).px,
        isNot(closeTo(kIPhone17Pro.size.height, 0.5)),
        reason: 'the viewport is not the ceiling; the largest detent is',
      );
    });
  });

  group('4. one child layout per frame', () {
    test('sixty drag updates cost exactly sixty child layouts', () {
      final rig = rigAtMedium();
      final drag = beginDrag(rig);

      for (var i = 0; i < 60; i++) {
        drag.update(1);
        rig.flush();
      }

      expect(
        rig.content.layouts,
        60,
        reason:
            'the standing guard against smooth_sheets two layouts plus an '
            'intrinsics walk. 120 is the shape of that regression',
      );
      expect(rig.content.dryLayouts, 0);
      expect(rig.content.intrinsics, 0);
    });

    test('a settling frame costs at most one, and the panel really moved', () {
      final rig = rigAtMedium();
      rig.model.animateTo(Detent.full);
      rig.flush();
      rig.content.reset();

      const step = Duration(microseconds: 16667);
      var frames = 0;
      while (rig.model.isTicking && frames < 200) {
        rig.model.tick(step);
        rig.flush();
        frames++;
      }

      expect(
        frames,
        greaterThan(20),
        reason: 'a settle that finished in three frames would prove nothing',
      );
      expect(
        rig.content.layouts,
        lessThanOrEqualTo(frames),
        reason: 'the budget. Two per frame is the regression',
      );
      // Not pinned to exactly `frames`: a tick whose spring sample rounds to
      // the extent already showing legitimately costs zero layouts, because
      // `applyExtent` declines to notify. Pinning equality would pin the
      // spring's floating point rather than the budget.
      expect(rig.content.layouts, greaterThan(20));
      expect(
        spanOf(rig.content.lastConstraints),
        closeTo(fullFrameOnPro, 1e-9),
        reason: 'and it arrived where it was going',
      );
      expect(rig.content.dryLayouts, 0);
    });

    test('a frame where nothing moved costs none', () {
      final rig = rigAtMedium();
      rig.content.reset();

      rig.flush();
      rig.flush();

      expect(
        rig.content.layouts,
        0,
        reason: 'an idle panel is free, and stays free for a second frame',
      );
      expect(rig.host.debugNeedsLayout, isFalse);
      expect(rig.panel.debugNeedsLayout, isFalse);
      // Stated plainly because a mutation sweep found it: this assertion has no
      // partner in the render layer. A panel that re-dirties itself inside
      // `performLayout` does not land here — `layout` clears `_needsLayout`
      // after `performLayout` returns, so the framework erases the self-dirty
      // and the debug assert in `markNeedsLayout` is what catches it, one test
      // up. The discriminating version of this claim is the widget-level one,
      // `panel_viewport_test.dart`'s "a rebuild that changed nothing lays
      // nothing out", which fails the moment a setter loses its `==` guard.
    });
  });

  group('where the panel sits, and what it declines to swallow', () {
    test('the panel takes no layer of its own', () {
      final rig = rigAtMedium();

      expect(
        rig.panel.isRepaintBoundary,
        isFalse,
        reason:
            'recorded as a decision rather than left as a drift. '
            '`RenderObject.layout` ends in `markNeedsPaint`, which for a '
            'non-boundary walks to the parent — so the per-frame '
            'markNeedsLayout that stops at this box becomes a per-frame '
            'markNeedsPaint that does not, and a panel animating over a static '
            'background repaints it. A7 schedules that work for after the first '
            'ported example, deliberately: until one runs, a repaint budget is '
            'a guess. This line is where flipping it has to be admitted',
      );
    });

    test('the panel fills its box and the rect sits at the bottom of it', () {
      final rig = rigAtMedium();

      expect(
        rig.panel.size,
        kIPhone17Pro.size,
        reason:
            'sizedByParent: the box is the viewport, the panel is a rect in it',
      );
      final rect = rig.panel.panelRect;
      expect(rect.left, 0);
      expect(rect.right, kIPhone17Pro.size.width);
      expect(rect.bottom, kIPhone17Pro.size.height);
      expect(rect.top, closeTo(874 - mediumFrameOnPro, 1e-9));
    });

    test('the child is placed at the rect, not at the box origin', () {
      final rig = rigAtMedium();
      final data = rig.content.parentData! as BoxParentData;

      expect(data.offset.dx, 0);
      expect(
        data.offset.dy,
        closeTo(874 - mediumFrameOnPro, 1e-9),
        reason:
            'a child painted at the origin would look like a top sheet and hit '
            'test like one, and nothing about its size would say so',
      );
    });

    test('a tap above the panel falls through it', () {
      final rig = rigAtMedium();

      final above = BoxHitTestResult();
      expect(
        rig.panel.hitTest(above, position: const Offset(200, 100)),
        isFalse,
        reason:
            'the panel box covers the whole viewport, so hitTestSelf must be '
            'false — otherwise a non-modal sheet over a map makes the map dead, '
            'and a barrier never sees a dismissing tap',
      );

      final inside = BoxHitTestResult();
      expect(
        rig.panel.hitTest(inside, position: const Offset(200, 800)),
        isTrue,
      );
      expect(
        inside.path.map((entry) => entry.target),
        contains(rig.content),
        reason: 'and the hit reached the content, at the offset it was placed',
      );
    });
  });

  group('lifetime', () {
    test('handing the panel a new model moves the listener with it', () {
      final rig = rigAtMedium();
      final replacement = openAtMedium();
      addTearDown(replacement.dispose);

      rig.panel.model = replacement;
      rig.flush();

      final stale = DragPanelActivity(from: rig.model.extent);
      rig.model.beginActivity(stale);
      stale.update(40);
      expect(
        rig.panel.debugNeedsLayout,
        isFalse,
        reason:
            'the model this panel was built with is not its model any more, and '
            'a listener left on it is a panel driven by two things — the second '
            'of which nothing will ever dispose',
      );

      final live = DragPanelActivity(from: replacement.extent);
      replacement.beginActivity(live);
      live.update(40);
      expect(
        rig.panel.debugNeedsLayout,
        isTrue,
        reason: 'and the new one drives it, which is the other half',
      );
    });

    test('and lays out again, against the model it was just handed', () {
      // The paged-host case the setter documents: one panel, a new model per
      // page. The replacement is deliberately built against a *different*
      // device and opened at a different detent, so three numbers separate a
      // panel that re-laid-out from one that did not — 812 for `.full` in this
      // box, 894 for `.full` in the box the replacement thinks it is in, and
      // 469.68 for the outgoing model's `.medium`.
      //
      // The two tests above this one stop one step short of it: one asserts the
      // *listener* moved and the other asserts identity, and neither asks what
      // the panel is then laid out at. A mutation sweep deleted the setter's
      // `markNeedsLayout` and both stayed green.
      final rig = rigAtMedium();
      final replacement = PanelModel(
        config: const PanelConfig(detents: _sheet, initialDetent: Detent.full),
        layout: kIPhone17ProMax.layout(),
      );
      addTearDown(replacement.dispose);
      rig.content.reset();

      rig.panel.model = replacement;
      rig.flush();

      expect(
        rig.content.layouts,
        1,
        reason:
            'asserted before the height, because without the layout the failure '
            'below is a "Bad state: No element" out of the harness rather than '
            'a panel showing the outgoing model height',
      );
      expect(
        spanOf(rig.content.lastConstraints),
        closeTo(fullFrameOnPro, 1e-9),
        reason:
            'the new model opens at .full, and .full in *this* box is 812. '
            'Without the setter markNeedsLayout the panel keeps the outgoing '
            'model 469.68 forever — the replacement never notifies, because '
            'nothing has happened to it',
      );
      expect(
        replacement.layout.baseline.viewportSpan.px,
        874,
        reason:
            'and the model learned which box it is in. It was constructed '
            'against a 17 Pro Max, so a panel that never laid it out leaves it '
            'resolving every detent against 956 — a device it is not on',
      );
    });

    test('a panel put back in the tree catches up with a model that moved', () {
      final rig = rigAtMedium();
      rig.content.reset();

      // Out of the tree — `dropChild` detaches it — and then the model moves
      // with nothing listening. A route rebuilt over a settle that never
      // stopped is the case, and it is why `attach` marks needs-layout at all.
      rig.host.child = null;
      rig.model.goIdle(target: Detent.full);
      expect(
        rig.panel.debugNeedsLayout,
        isFalse,
        reason: 'nothing reached it, which is the other half of detach',
      );

      rig.host.child = rig.panel;
      rig.flush();

      expect(
        rig.content.layouts,
        1,
        reason:
            'the panel laid out again on the way back in. Asserted before the '
            'height below, because without it the failure is a "Bad state: No '
            'element" out of the harness rather than a stale panel',
      );
      expect(
        spanOf(rig.content.lastConstraints),
        closeTo(fullFrameOnPro, 1e-9),
        reason:
            'nothing recorded what the model did while the panel was away, so '
            'the only safe assumption on the way back is that it did something. '
            'Without the markNeedsLayout in attach the constraints are '
            'unchanged and RenderObject.layout returns early, so the panel '
            'shows the height it had before it left — forever, because the '
            'model has already notified',
      );
    });

    test('and a panel taken out of the tree stops listening', () {
      final rig = rigAtMedium();

      // What the framework does when the widget is removed: `dropChild` on the
      // host detaches the panel.
      rig.host.child = null;

      final drag = DragPanelActivity(from: rig.model.extent);
      rig.model.beginActivity(drag);
      drag.update(40);

      expect(
        rig.panel.debugNeedsLayout,
        isFalse,
        reason:
            'a listener on a model that outlives the render object is a leak '
            'and, worse, a notification into a render object with no owner. The '
            'model outlives this panel by design — it holds a settle across a '
            'route rebuild — so detach is the only thing that ends the link',
      );
    });
  });

  group('refusals', () {
    // Three constraint shapes, because one is not enough to say what the
    // refusal reads. `const BoxConstraints()` is unbounded on *both* axes, and
    // there `hasBoundedWidth && hasBoundedHeight`, `||`, width-alone and
    // height-alone all answer the same thing — so a refusal written any of the
    // four ways passes. A mutation sweep found exactly that: three separate
    // mutants of this condition survived against that input alone.
    //
    // The two half-bounded shapes are the discriminating ones, and both are
    // real: a panel in a `Row` with no `Expanded` is bounded in height and
    // unbounded in width, and a panel in a `Column` with no `Expanded` is the
    // mirror. Under `||` neither refuses at all.
    const shapes = <String, BoxConstraints>{
      'a Column and a Row with no Expanded in either': BoxConstraints(),
      'a Row with no Expanded — bounded in height alone': BoxConstraints(
        maxHeight: 400,
      ),
      'a Column with no Expanded — bounded in width alone': BoxConstraints(
        maxWidth: 402,
      ),
    };

    for (final shape in shapes.entries) {
      test('a panel unbounded in ${shape.key} says so', () {
        expect(
          () => rigAtMedium(childConstraints: shape.value),
          throwsA(
            isA<AssertionError>().having(
              (error) => error.toString(),
              'message',
              contains('detent'),
            ),
          ),
          reason:
              'a panel fills what it is given, so an unbounded constraint makes '
              'the viewport infinite and every detent with it. Matching on '
              '"detent" and not merely on AssertionError is the point: without '
              'our own refusal the framework still stops, with '
              '"RenderPanelViewport object was given an infinite size during '
              'layout", which names the symptom three layers below the mistake',
        );
      });
    }

    test('a panel handed a negative extent refuses before the framework', () {
      final rig = rigAtMedium();

      // A drag, because `LayoutCorrection.freeze` is the one correction that
      // answers `current`: under any other the commit re-resolves the detent
      // and the extent written below never reaches the constraints. The number
      // is the one measured out of a `bouncy` settle onto a zero-height detent.
      final drag = DragPanelActivity(from: rig.model.extent);
      rig.model.beginActivity(drag);
      rig.flush();
      rig.model.applyExtent(const Extent(-0.9));

      expect(
        rig.flush,
        throwsA(
          isA<AssertionError>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('absent'), contains('EdgeOffset')),
          ),
        ),
        reason:
            'this is the only place an Extent becomes a BoxConstraints. '
            'Without the gate the framework refuses instead — "BoxConstraints '
            'has a negative minimum height", reported against the content, '
            'three layers below whatever produced the extent — and panelRect, '
            'which is public, is recorded inverted on the way past. '
            'SettlingPanelActivity.tick saturates so this is unreachable from '
            'a spring; the gate is what makes it unreachable from anything',
      );
    });

    test('a panel asked for an intrinsic refuses rather than answering 0', () {
      final rig = rigAtMedium();

      for (final ask in <String, double Function()>{
        'getMinIntrinsicHeight': () => rig.panel.getMinIntrinsicHeight(402),
        'getMaxIntrinsicHeight': () => rig.panel.getMaxIntrinsicHeight(402),
        'getMinIntrinsicWidth': () => rig.panel.getMinIntrinsicWidth(874),
        'getMaxIntrinsicWidth': () => rig.panel.getMaxIntrinsicWidth(874),
      }.entries) {
        expect(
          ask.value,
          throwsA(
            isA<FlutterError>().having(
              (error) => error.toString(),
              'message',
              allOf(contains('intrinsic dimensions'), contains('detent')),
            ),
          ),
          reason:
              '${ask.key}: RenderBox answers 0.0 by default, and a 0.0 from '
              'this box is not a small answer but a wrong one. An '
              'IntrinsicHeight around a panel hands it a *bounded*, tight zero '
              '— which sails past computeDryLayout, whose assert only catches '
              'unbounded — and the panel then lays its child out 34pt tall '
              'entirely above its own zero-height box, silently. RenderViewport '
              'refuses for the same reason (viewport.dart:705-749)',
        );
      }
    });

    test('and answers 0 while the framework is checking intrinsics', () {
      final rig = rigAtMedium();
      RenderObject.debugCheckingIntrinsics = true;
      addTearDown(() => RenderObject.debugCheckingIntrinsics = false);

      expect(
        rig.panel.getMinIntrinsicHeight(402),
        0,
        reason:
            'the other half of RenderViewport shape: debugCheckIntrinsicSizes '
            'walks a whole tree asking every box, and a refusal that fired '
            'there would make this panel the one render object nobody can run '
            'the framework own consistency check over',
      );
    });
  });

  group('the policies this slice does not ship refuse by name', () {
    test('PanelSizing.translate', () {
      expect(
        () => rigAtMedium(sizing: PanelSizing.translate),
        throwsA(
          isA<UnimplementedError>().having(
            (error) => error.message,
            'message',
            contains('PanelSizing.translate'),
          ),
        ),
        reason:
            'named, the way PanelAnchor.rectOf names the four anchors it does '
            'not ship. A bare UnimplementedError would let this test pass '
            'against a file that is entirely unimplemented, which is exactly '
            'the state this one is in',
      );
    });

    test('PanelSizing.clip', () {
      expect(
        () => rigAtMedium(sizing: PanelSizing.clip),
        throwsA(
          isA<UnimplementedError>().having(
            (error) => error.message,
            'message',
            contains('PanelSizing.clip'),
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // Everything below this line was added while implementing the layer. Each
  // covers something no assertion above could see: a field the panel could
  // silently drop, a branch nothing reached, or an answer nothing read.
  // ==========================================================================

  group('the constructor policies reach the layout, not just the field', () {
    test('a floating panel gives its detents none of the edge padding', () {
      final rig = rigAtMedium(attachment: EdgeAttachment.floating);

      expect(
        spanOf(rig.content.lastConstraints),
        closeTo(mediumFloatingOnPro, 1e-9),
        reason:
            'floating means the frame is all content: frameOf adds an '
            'attachedPadding of zero, so .medium is 435.68 rather than 469.68. '
            'That is the whole of what this field does, and V6 is the open '
            'question it exists to answer in one line',
      );
      expect(
        spanOf(rig.content.lastConstraints),
        isNot(closeTo(mediumFrameOnPro, 0.5)),
        reason:
            'a panel that took the attachment and then handed baselineFor a '
            'hardcoded edgeAttached would land here, and every other assertion '
            'in this file would stay green',
      );
    });

    test('the anchor reaches rectOf, which is what refuses the other four', () {
      expect(
        () => rigAtMedium(anchor: PanelAnchor.top),
        throwsA(
          isA<UnimplementedError>().having(
            (error) => error.message,
            'message',
            contains('PanelAnchor.top'),
          ),
        ),
        reason:
            'not a claim about top sheets — it is the only observable proof '
            'that the anchor field is the one rectOf is called with. A panel '
            'that hardcoded bottom would lay a top sheet out along the bottom '
            'and say nothing',
      );
    });

    test('the media the panel was given is the layout the model commits', () {
      // Deliberately not the 17 Pro's own numbers. `PanelModel` is constructed
      // from `kIPhone17Pro.layout()`, which already carries devicePixelRatio 3
      // and LTR — so asserting those would also be satisfied by a panel that
      // never committed a layout at all. Two values nothing in this slice reads
      // yet, chosen so that only the bridge can be the source of them.
      final rig = rigAtMedium(
        media: PanelMedia(
          viewPadding: kIPhone17Pro.viewPadding,
          viewInsets: const EdgeInsets.only(bottom: 336),
          devicePixelRatio: 2,
          textDirection: TextDirection.rtl,
        ),
      );

      expect(rig.model.layout.devicePixelRatio, 2);
      expect(rig.model.layout.textDirection, TextDirection.rtl);
      expect(
        rig.model.layout.viewInsets.bottom,
        336,
        reason:
            'three fields of PanelMedia that no detent may see and that nothing '
            'in this slice reads. Without this the panel could build its '
            'PanelLayout out of constants and the 469.68 below would still hold',
      );
      expect(
        spanOf(rig.content.lastConstraints),
        closeTo(mediumFrameOnPro, 1e-9),
        reason:
            'and none of the three moved a detent — the keyboard least of all, '
            'which is KB6 from the render layer',
      );
    });
  });

  group('the setters take, and decline', () {
    test('attachment', () {
      final rig = rigAtMedium();
      rig.content.reset();

      rig.panel.attachment = EdgeAttachment.edgeAttached;
      expect(
        rig.panel.debugNeedsLayout,
        isFalse,
        reason: 'the == guard, which is what makes an idle rebuild free',
      );

      rig.panel.attachment = EdgeAttachment.floating;
      expect(rig.panel.attachment, EdgeAttachment.floating);
      expect(rig.panel.debugNeedsLayout, isTrue);
      rig.flush();

      expect(
        spanOf(rig.content.lastConstraints),
        closeTo(mediumFloatingOnPro, 1e-9),
      );
    });

    test('sizing', () {
      final rig = rigAtMedium();

      rig.panel.sizing = PanelSizing.resize;
      expect(rig.panel.debugNeedsLayout, isFalse);

      rig.panel.sizing = PanelSizing.translate;
      expect(rig.panel.sizing, PanelSizing.translate);
      expect(rig.panel.debugNeedsLayout, isTrue);
      expect(
        rig.flush,
        throwsA(isA<UnimplementedError>()),
        reason:
            'the policy is read at layout time and not remembered from '
            'construction, which is the only reason a setter for it exists',
      );
    });

    test('measuresContent', () {
      final rig = rigAtMedium();
      expect(rig.content.dryLayouts, 0);

      rig.panel.measuresContent = false;
      expect(rig.panel.debugNeedsLayout, isFalse);

      rig.panel.measuresContent = true;
      expect(rig.panel.measuresContent, isTrue);
      expect(rig.panel.debugNeedsLayout, isTrue);
      rig.flush();

      expect(
        rig.content.dryLayouts,
        1,
        reason:
            'a detent set that gains a content detent turns this on mid-life, '
            'and the panel has to start asking on the very next pass',
      );
    });

    test('anchor', () {
      final rig = rigAtMedium();

      rig.panel.anchor = PanelAnchor.bottom;
      expect(rig.panel.debugNeedsLayout, isFalse);

      // `top` and not `leading`: a horizontal anchor makes `Detent.medium`
      // refuse first — 0.56 of a width is not a measurement of anything — and
      // that assertion would arrive from `geometry/` before this layer had said
      // anything, which is a test of the detent rather than of the setter.
      rig.panel.anchor = PanelAnchor.top;
      expect(rig.panel.anchor, PanelAnchor.top);
      expect(rig.panel.debugNeedsLayout, isTrue);
      expect(
        rig.flush,
        throwsA(
          isA<UnimplementedError>().having(
            (error) => error.message,
            'message',
            contains('PanelAnchor.top'),
          ),
        ),
      );
    });
  });

  group('measuring, in the cases the happy path does not reach', () {
    test('a panel with no content measures nothing, and does not refuse', () {
      final rig = rigAtMedium(withChild: false, measuresContent: true);

      expect(
        rig.panel.measureContent(kIPhone17Pro.panelBaseline()),
        Extent.zero,
        reason:
            'a content detent in a set with no child is a configuration '
            'mistake that should resolve to a visible zero-height stop, not to '
            'an exception thrown from inside a layout pass',
      );
      expect(
        rig.model.layout.contentExtent,
        Extent.zero,
        reason: 'and the pass that just ran committed exactly that',
      );
    });

    test('the anchor reaches the baseline the content is measured against', () {
      final rig = rigAtMedium(measuresContent: true);
      expect(
        rig.content.lastDryConstraints.maxHeight,
        closeTo(fullFrameOnPro, 1e-9),
      );

      rig.panel.anchor = PanelAnchor.top;
      expect(rig.flush, throwsA(isA<UnimplementedError>()));

      expect(
        rig.content.lastDryConstraints.maxHeight,
        closeTo(kIPhone17Pro.baseline + kIPhone17Pro.viewPadding.top, 1e-9),
        reason:
            'a top sheet absorbs the 62pt notch where a bottom one absorbs the '
            '34pt home indicator, so its .full frame is 840 rather than 812. '
            'The panel cannot finish a layout for one yet — rectOf refuses — '
            'and the baseline it measured against is the only place the anchor '
            'is observable before that refusal. Without this, baselineFor could '
            'be handed a hardcoded bottom and every other test would pass',
      );
    });

    test('content that cannot decide its own length is refused', () {
      // DESIGN.md §2.5's tripwire, on the one input it is written for: content
      // whose measured span alternates. Each pass would resolve a content
      // detent to a height that makes the next pass measure the other one, so
      // the panel lays out forever at the frame rate and the budget this whole
      // layer is measured by stops having an upper bound.
      final model = openAtMedium();
      addTearDown(model.dispose);
      final content = _DitheringBox(a: 240, b: 360);
      final rig = PanelRig(
        model: model,
        content: content,
        measuresContent: true,
      );
      addTearDown(rig.dispose);

      // A dirty content is what clears `getDryLayout`'s per-constraints memo
      // and escalates to the panel, so each flush is a genuinely fresh measure
      // rather than the cache answering. Two more passes: 240, 360, 240.
      content.markNeedsLayout();
      rig.flush();
      expect(
        content.dryLayouts,
        2,
        reason: 'two measurements so far, differing',
      );

      content.markNeedsLayout();
      expect(
        rig.flush,
        throwsA(
          isA<AssertionError>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('alternated'), contains('240'), contains('360')),
          ),
        ),
        reason:
            'three is the shortest history that tells an oscillation from a '
            'change: two different answers in a row are content that grew, '
            'which is the ordinary case and the whole reason a content detent '
            're-measures at all',
      );
    });

    test('the measure asks along the baseline span axis, not along height', () {
      final rig = rigAtMedium(measuresContent: true);
      // A drawer's geometry on the same phone: the span is the 402pt width and
      // the pinned cross span is the 874pt height. Deliberately the baseline
      // rather than the panel's anchor — `measureContent` takes the baseline,
      // so the baseline is what decides which question is being asked, and a
      // measure that read `Size.height` regardless would answer 874 here.
      final drawer = kIPhone17Pro.panelBaseline(anchor: PanelAnchor.leading);

      expect(rig.panel.measureContent(drawer).px, 402);
      expect(
        rig.panel.measureContent(drawer).px,
        isNot(kIPhone17Pro.size.height),
        reason: 'which is what a hardcoded vertical measure would answer',
      );
      expect(rig.content.lastDryConstraints.hasTightHeight, isTrue);
      expect(
        rig.content.lastDryConstraints.hasTightWidth,
        isFalse,
        reason:
            'the cross axis is pinned and the span axis is the question, '
            'and which is which comes from the baseline',
      );
    });
  });

  group('painting, and the transform that goes with it', () {
    test('the child is painted at the rect, offset by the caller', () {
      final rig = rigAtMedium();
      final context = _RecordingContext();

      // A non-zero incoming offset, because zero cannot tell "adds the child's
      // placement" from "ignores the incoming offset".
      rig.panel.paint(context, const Offset(7, 11));

      expect(context.painted.single.$1, rig.content);
      expect(context.painted.single.$2.dx, 7);
      expect(
        context.painted.single.$2.dy,
        closeTo(11 + 874 - mediumFrameOnPro, 1e-9),
        reason:
            'painting re-derives no geometry: it reads the offset layout wrote '
            'into the parent data, so the frame the content was given and the '
            'frame the user sees cannot drift apart',
      );
    });

    test('a panel with no child paints nothing rather than failing', () {
      final rig = rigAtMedium(withChild: false);
      final context = _RecordingContext();

      rig.panel.paint(context, Offset.zero);

      expect(context.painted, isEmpty);
    });

    test('the paint transform carries the same placement', () {
      final rig = rigAtMedium();
      final transform = Matrix4.identity();

      rig.panel.applyPaintTransform(rig.content, transform);

      expect(
        MatrixUtils.transformPoint(transform, Offset.zero),
        within(
          distance: 1e-9,
          from: Offset(0, 874 - mediumFrameOnPro),
          distanceFunction: (Offset a, Offset b) => (a - b).distance,
        ),
        reason:
            'localToGlobal from inside the panel is how a scrollable in the '
            'content works out where it is on screen, so an identity here is a '
            'scroll handoff that mis-locates every gesture by the panel top',
      );
    });

    test('a panel with no child declines every hit', () {
      final rig = rigAtMedium(withChild: false);

      final result = BoxHitTestResult();
      expect(
        rig.panel.hitTest(result, position: const Offset(200, 800)),
        isFalse,
      );
    });
  });

  group('diagnostics', () {
    test('the panel names the four things a wrong height is explained by', () {
      final rig = rigAtMedium();
      final properties = DiagnosticPropertiesBuilder();

      rig.panel.debugFillProperties(properties);
      final named = {
        for (final property in properties.properties) property.name: property,
      };

      expect(
        named.keys,
        containsAll(<String>['extent', 'panelRect', 'sizing', 'activity']),
        reason:
            '"the panel is the wrong height" is answered by which of those four '
            'is surprising, and reading it out of a dump beats adding a print',
      );
      expect(named['extent']!.value, closeTo(mediumFrameOnPro, 1e-9));
      expect(named['panelRect']!.value, rig.panel.panelRect);
    });

    test('a panel that has never been laid out says so instead of throwing', () {
      final model = openAtMedium();
      addTearDown(model.dispose);
      final panel = RenderPanelViewport(model: model, media: portraitMedia);
      addTearDown(panel.dispose);

      final properties = DiagnosticPropertiesBuilder();
      expect(() => panel.debugFillProperties(properties), returnsNormally);
      final rect = properties.properties.singleWhere(
        (property) => property.name == 'panelRect',
      );
      expect(
        rect.toDescription(),
        'not laid out yet',
        reason:
            'a render-tree dump is what someone reaches for once a layout pass '
            'has already failed, and a diagnostics method that throws turns '
            'that into a second, unrelated failure on top of the first',
      );
      expect(
        rect.level,
        DiagnosticLevel.warning,
        reason:
            'and it is raised rather than merely printed — `missingIfNull`. '
            'A panel with no rect has not run yet, which means every other '
            'number in the dump is from before it did, and that is the first '
            'thing the reader needs to know rather than the last',
      );

      expect(
        () => panel.panelRect,
        throwsA(isA<AssertionError>()),
        reason:
            'the getter still refuses. There is no rect yet, and answering '
            'Rect.zero would put a panel at the top-left corner of the screen '
            'with no way to tell that from a real answer',
      );
    });
  });

  group('PanelMedia is a value', () {
    PanelMedia media({
      EdgeInsets viewPadding = const EdgeInsets.only(top: 62, bottom: 34),
      EdgeInsets viewInsets = EdgeInsets.zero,
      double devicePixelRatio = 3,
      TextDirection textDirection = TextDirection.ltr,
    }) => PanelMedia(
      viewPadding: viewPadding,
      viewInsets: viewInsets,
      devicePixelRatio: devicePixelRatio,
      textDirection: textDirection,
    );

    test('it joins its four values to a viewport the widget cannot see', () {
      // The only test in this file that reaches a directional anchor, and the
      // only place the reading direction is observable at all: for a bottom
      // sheet `attachedPadding` is `viewPadding.bottom` whichever way the text
      // runs, so an implementation that dropped `textDirection` on the way into
      // `PanelBaseline.from` would be invisible everywhere else. A drawer
      // hangs off the reading-start edge, and these two insets differ.
      final lopsided = media(
        viewPadding: const EdgeInsets.only(left: 44, right: 11),
      );
      const viewport = Size(402, 874);

      expect(
        lopsided
            .baselineFor(
              viewport,
              anchor: PanelAnchor.leading,
              attachment: EdgeAttachment.edgeAttached,
            )
            .attachedPadding,
        const Extent(44),
      );
      expect(
        media(
              viewPadding: const EdgeInsets.only(left: 44, right: 11),
              textDirection: TextDirection.rtl,
            )
            .baselineFor(
              viewport,
              anchor: PanelAnchor.leading,
              attachment: EdgeAttachment.edgeAttached,
            )
            .attachedPadding,
        const Extent(11),
        reason:
            'a drawer mirrors in RTL without the app asking, and this is the '
            'one call that carries the direction far enough for it to',
      );
      expect(
        lopsided
            .baselineFor(
              viewport,
              anchor: PanelAnchor.leading,
              attachment: EdgeAttachment.floating,
            )
            .attachedPadding,
        Extent.zero,
        reason: 'and a floating drawer absorbs neither',
      );
    });

    test('two readings of the same MediaQuery are one value', () {
      // What this buys is the whole reason the four values are one field: the
      // media setter compares once, and a rebuild that changed nothing marks
      // nothing dirty. Four separate fields would be four chances to forget it.
      expect(media(), media());
      expect(media().hashCode, media().hashCode);
      final same = media();
      expect(same, same);
      expect(media(), isNot(const Object()));
    });

    test('every field is part of the identity', () {
      expect(media(), isNot(media(viewPadding: EdgeInsets.zero)));
      expect(
        media(),
        isNot(media(viewInsets: const EdgeInsets.only(bottom: 336))),
        reason:
            'the keyboard moves nothing a detent can see, and it must still '
            'reach the render object — a KeyboardPolicy reads it',
      );
      expect(media(), isNot(media(devicePixelRatio: 2)));
      expect(media(), isNot(media(textDirection: TextDirection.rtl)));
    });

    test('it says what it is', () {
      expect(
        media(viewInsets: const EdgeInsets.only(bottom: 336)).toString(),
        allOf(
          contains('viewPadding'),
          contains('viewInsets'),
          contains('336'),
          contains('devicePixelRatio: 3'),
          contains('textDirection: ltr'),
        ),
      );
    });
  });
}
