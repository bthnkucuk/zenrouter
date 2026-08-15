import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/baseline.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/layout.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/model/correction.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/physics/motion.dart';
import 'package:shits/src/physics/snap.dart';

import '../fixtures/devices.dart';

// ============================================================================
// The model is two scalars, an activity, and one place a layout change lands.
//
// The headline is the group named for it: the sizing pass and the commit go
// through one expression, so they cannot answer differently. `smooth_sheets`
// ships two implementations and asserts afterwards that they agreed
// (`lib/src/model.dart:345-361`) — on exact `double` equality, against a value
// fresh out of a spring. There is nothing here for that assert to compare.
// ============================================================================

const _peek = Detent.height(DetentValue(180));
const _sheet = DetentSet([_peek, Detent.medium, Detent.full]);
const _config = PanelConfig(detents: _sheet, initialDetent: Detent.medium);

/// A scroll position that is only three numbers, which is all the model asks of
/// one.
final class _FakeScroll implements PanelScrollDriver {
  @override
  double pixels = 0;

  @override
  double minScrollExtent = 0;

  @override
  double maxScrollExtent = 2000;
}

/// An iPhone 17 Pro on its side, where iOS deactivates the medium detent.
const _landscape = PanelLayout(
  baseline: PanelBaseline(
    safeSpan: Baseline(381),
    viewportSpan: ViewportExtent(402),
    attachedPadding: Extent(21),
    crossSpan: 874,
    isCompactHeight: true,
    spanAxis: Axis.vertical,
  ),
  viewInsets: EdgeInsets.zero,
  contentExtent: null,
  devicePixelRatio: 3,
  textDirection: TextDirection.ltr,
);

/// The same phone on a 1x display, which no measured fixture is.
///
/// Every row of `test/fixtures/devices.dart` is 3x, so `0.5 / devicePixelRatio`
/// and the hand-built `kSettleTolerance` — which is 0.5/3 — are the same number
/// in every other test in this package, and the plumbing between them is
/// unfalsifiable without one of these.
final _lowDensity = PanelLayout(
  baseline: kIPhone17Pro.panelBaseline(),
  viewInsets: EdgeInsets.zero,
  contentExtent: null,
  devicePixelRatio: 1,
  textDirection: TextDirection.ltr,
);

void main() {
  final portrait = kIPhone17Pro.layout();
  final bigger = kIPhone17ProMax.layout();
  final withKeyboard = kIPhone17Pro.layout(
    viewInsets: const EdgeInsets.only(bottom: 336),
  );

  final detents = _sheet.resolve(portrait.baseline);
  final peek = detents.extentOf(_peek)!;
  final medium = detents.extentOf(Detent.medium)!;
  final full = detents.extentOf(Detent.full)!;

  PanelModel newModel({PanelConfig config = _config}) =>
      PanelModel(config: config, layout: portrait);

  group('a panel opens where it was told to', () {
    test('at its initial detent, as a detent and not as a height', () {
      final model = newModel();
      expect(model.config, _config);
      expect(model.layout, portrait);
      expect(model.extent.px, closeTo(medium.px, 1e-9));
      expect(model.activity, isA<IdlePanelActivity>());
      expect((model.activity as IdlePanelActivity).target, Detent.medium);
      expect(model.isTicking, isFalse);
    });

    test('and at the smallest active one when none was named', () {
      final model = newModel(config: const PanelConfig(detents: _sheet));
      expect(model.extent.px, peek.px);
      expect((model.activity as IdlePanelActivity).target, _peek);
    });

    test('and fully present, because a detent is not a dismissal', () {
      final model = newModel();
      expect(model.edgeOffset, EdgeOffset.zero);
      expect(model.restingOffset, EdgeOffset.zero);
      for (final (_, extent) in model.detents.snaps) {
        model.applyExtent(extent);
        expect(
          model.presentationProgress,
          1.0,
          reason: 'a barrier behind a half-height sheet is fully opaque',
        );
      }

      // And not unconditionally, which is all the row above can say on its own:
      // both offsets are pinned at zero in this slice, so the expression is
      // 1.0 for every extent that has a span, and a hardcoded 1.0 would pass.
      // A panel with no span is the one input that separates them, and a drag
      // deep enough to saturate the band below the smallest detent reaches it.
      model.applyExtent(Extent.zero);
      expect(
        model.presentationProgress,
        0.0,
        reason: 'a panel of no span is not a fully present panel',
      );
    });

    test('and at its named detent even where this layout has not got one', () {
      // A panel opened at `.medium` on a phone already on its side, where iOS
      // deactivates medium. It opens at the height that exists and keeps the
      // detent that does not, so turning the phone upright is not a one-way
      // trip — the same rule `LayoutCorrection.hold` follows, applied at frame
      // zero. Recording what `select` opened at instead would make the fallback
      // permanent.
      final model = PanelModel(config: _config, layout: _landscape);
      expect(model.detents.extentOf(Detent.medium), isNull);
      expect(
        model.extent.px,
        201.0,
        reason: 'select opens at the smallest active stop',
      );
      expect((model.activity as IdlePanelActivity).target, Detent.medium);

      model.applyLayout(portrait);
      expect(
        model.extent.px,
        closeTo(medium.px, 1e-9),
        reason: 'and the detent it was holding is the one the author named',
      );
    });
  });

  group('the sizing pass and the commit cannot disagree', () {
    test('for every layout change, whatever the panel is doing', () {
      for (final next in [bigger, withKeyboard, _landscape, portrait]) {
        final model = newModel();
        final dry = model.dryApplyLayout(next);

        expect(
          model.extent.px,
          closeTo(medium.px, 1e-9),
          reason: 'the sizing pass commits nothing',
        );
        expect(model.layout, portrait, reason: 'nor the layout');

        model.applyLayout(next);
        expect(model.extent.px, dry.px, reason: 'on $next');
        expect(model.layout, next);
      }
    });

    test('and asking twice asks the same question', () {
      final model = newModel();
      var notifications = 0;
      model.addListener(() => notifications++);

      expect(model.dryApplyLayout(bigger).px, model.dryApplyLayout(bigger).px);
      expect(
        notifications,
        0,
        reason: 'the debug tripwire is purity, and this is what it watches',
      );
    });

    test(
      'and a pass that changes nothing still resolves, and says nothing',
      () {
        // The two halves of deleting the early-out. A pass that moves nothing
        // notifies nobody — that is what `if (next == _layout) return` was
        // actually carrying, and comparing the *outcome* carries it without
        // skipping the resolve.
        final model = newModel();
        final same = kIPhone17Pro.layout();
        expect(identical(same, model.layout), isFalse);
        expect(same, model.layout);

        var notifications = 0;
        model.addListener(() => notifications++);
        model.applyLayout(same);
        expect(model.extent.px, closeTo(medium.px, 1e-9));
        expect(
          notifications,
          0,
          reason:
              'one value comparison, where smooth_sheets compares five '
              'fields by hand under a TODO to make the class immutable',
        );
      },
    );

    test('and a pass on an unchanged layout is where goIdle lands', () {
      // The other half, and the one the early-out got wrong. A correction is a
      // function of the *activity* as much as of the layout, so a pass that
      // changes no geometry still has an answer: `goIdle` moves the activity and
      // leaves the height to "the next layout pass, which answers it with
      // hold" — and a pass that refused to resolve never answered. The panel
      // then painted at the dry number while every consumer of `extent` — the
      // barrier, presentationProgress, the next drag's `from` — read the other
      // one, stably, until a gesture started.
      final model = newModel();
      model.goIdle(target: Detent.full);

      var notifications = 0;
      model.addListener(() => notifications++);

      final dry = model.dryApplyLayout(portrait);
      expect(dry.px, closeTo(full.px, 1e-9));

      model.applyLayout(portrait);
      expect(model.extent.px, dry.px);
      expect(
        notifications,
        1,
        reason: 'and 342pt of movement is a change, whatever the layout did',
      );
    });

    test('and the sub-pixel version of it, which is the one that ships', () {
      // Nothing dramatic is needed to reach the divergence: parking a panel a
      // fraction of a pixel off its detent does it, on the live path, with no
      // goIdle anywhere.
      final model = newModel();
      model.applyExtent(Extent(medium.px - 0.08));
      model.settleTo(Detent.medium);
      expect(model.activity, isA<IdlePanelActivity>());

      final dry = model.dryApplyLayout(portrait);
      model.applyLayout(portrait);
      expect(model.extent.px, dry.px);
      expect(model.extent.px, closeTo(medium.px, 1e-9));
    });
  });

  group('a layout change reaches an idle panel through its detent', () {
    test('so a bigger device gives a bigger medium', () {
      final model = newModel();
      model.applyLayout(bigger);
      expect(model.extent.px, closeTo(0.56 * 860 + 34, 1e-9));
      expect((model.activity as IdlePanelActivity).target, Detent.medium);
    });

    test('and the keyboard gives the same one', () {
      // KB6, structurally: `viewInsets` is on the layout and not on the
      // baseline, so no detent can see it. The layout did change, so this is
      // not the early-out path — the panel is asked and answers the same
      // number.
      final model = newModel();
      var notifications = 0;
      model.addListener(() => notifications++);

      model.applyLayout(withKeyboard);
      expect(model.layout, withKeyboard);
      expect(model.extent.px, closeTo(medium.px, 1e-9));
      expect(
        notifications,
        1,
        reason:
            'the layout moved even though the panel '
            'did not, and a keyboard-aware inset downstream has to hear it',
      );
    });

    test('and a rotation that deactivates it does not forget it', () {
      final model = newModel();
      model.applyLayout(_landscape);

      expect(model.detents.extentOf(Detent.medium), isNull);
      expect(
        model.extent.px,
        402.0,
        reason: 'the nearest surviving detent, which is full at 381 + 21',
      );
      expect(
        (model.activity as IdlePanelActivity).target,
        Detent.medium,
        reason:
            'still parked at medium — it is the detent that left, not the '
            'panel',
      );

      model.applyLayout(portrait);
      expect(
        model.extent.px,
        closeTo(medium.px, 1e-9),
        reason:
            'so turning the phone back restores it, with nothing having '
            'had to remember anything',
      );
    });
  });

  group('a correction is committed, not only resolved', () {
    // `resolve` answers where the panel *is*; what it is still *doing* is the
    // exhaustive switch on the other side of the commit, and that switch is the
    // only thing telling three of the four variants apart. Nothing in it may
    // move the extent: the sizing pass has already been believed, and the child
    // laid out against it.

    test('so a settle carries on toward where its destination moved to', () {
      final model = newModel();
      model.settleTo(Detent.full);
      model.tick(const Duration(milliseconds: 100));

      final midFlight = model.extent;
      final speed = model.activity.velocity;
      expect(speed.pxPerSecond, greaterThan(0));

      final dry = model.dryApplyLayout(bigger);
      model.applyLayout(bigger);
      expect(model.extent.px, dry.px);
      expect(
        model.extent.px,
        midFlight.px,
        reason: 'the destination moved, not the panel',
      );

      final settling = model.activity as SettlingPanelActivity;
      expect(settling.destination, Detent.full);
      expect(
        settling.to.px,
        closeTo(894, 1e-9),
        reason: 'full re-resolved on the bigger device, 860 + 34',
      );
      expect(settling.from.px, midFlight.px);
      expect(settling.elapsed, Duration.zero);
      expect(
        settling.motion.duration,
        const Duration(milliseconds: 400),
        reason: 'the time that was left, not a fresh 500',
      );
      expect(
        settling.motion.bounce,
        _config.motion.bounce,
        reason: 'the same spring in less time, not a different spring',
      );
      expect(
        settling.velocity.pxPerSecond,
        closeTo(speed.pxPerSecond, 1e-6),
        reason: 'it picks the motion up rather than restarting it',
      );
    });

    test('and each re-seed is no longer than the last, so they converge', () {
      // Content that keeps changing shortens the settle instead of restarting
      // it. Re-seeding the full duration every time is how a panel under
      // changing content never arrives.
      final model = newModel();
      model.settleTo(Detent.full);

      var previous = const PanelMotion.smooth().duration;
      for (final next in [bigger, portrait, bigger]) {
        model.tick(const Duration(milliseconds: 100));
        model.applyLayout(next);
        final settling = model.activity as SettlingPanelActivity;
        expect(settling.motion.duration, lessThan(previous));
        previous = settling.motion.duration;
      }
      expect(previous, const Duration(milliseconds: 200));
    });

    test('and two re-seeds with no frame between them are equal, not '
        'shorter', () {
      // Said plainly because the convergence argument above is easy to overstate:
      // it rests on the elapsed clock advancing, and nothing makes a driver tick
      // between two layout passes. Four passes in one frame re-seed four springs
      // of the same length, not four progressively shorter ones. What bounds it
      // regardless is the row below — a re-seed only happens when the
      // destination actually moved — and what the clock adds is that each one
      // that does happen is shorter than the last.
      final model = newModel();
      model.settleTo(Detent.full);
      model.tick(const Duration(milliseconds: 100));

      final durations = <Duration>[];
      for (final next in [bigger, portrait, bigger, portrait]) {
        model.applyLayout(next);
        durations.add(
          (model.activity as SettlingPanelActivity).motion.duration,
        );
      }
      expect(durations, everyElement(const Duration(milliseconds: 400)));
    });

    test('and a pass that moved no detent does not re-seed at all', () {
      // The convergence argument above rests on the clock advancing between
      // passes, and nothing makes a driver tick between two of them. What makes
      // it converge regardless is that a re-seed is a response to the
      // destination *moving*: `applyLayout` runs once per frame in a real render
      // pass and most of those frames move nothing, and a settle re-seeded on
      // each of them is a fresh spring every frame whose own clock restarts each
      // time. A keyboard is the case — `viewInsets` move and no detent does.
      final model = newModel();
      model.settleTo(Detent.full);
      model.tick(const Duration(milliseconds: 100));
      final settling = model.activity as SettlingPanelActivity;

      model.applyLayout(withKeyboard);
      model.applyLayout(withKeyboard);
      model.applyLayout(kIPhone17Pro.layout());

      expect(model.activity, same(settling));
      expect(
        settling.elapsed,
        const Duration(milliseconds: 100),
        reason: 'three passes, and the settle is the one that was running',
      );
      expect(settling.motion.duration, const Duration(milliseconds: 500));
    });

    test('and not when its destination is one this layout has not got', () {
      // The row above re-seeds nothing because the destination's height is the
      // same number read twice out of the same set. This is the same claim
      // where that number comes out of `heightOf`'s *fallback* instead: the
      // settle is heading for a detent this layout deactivated, so both sides
      // of the guard are "the surviving stop nearest the panel", and both have
      // to be asked from where the panel actually is. Asked from anywhere else
      // — `Extent.zero` will do — the fallback answers the smallest stop, the
      // guard reports that the destination moved on a pass that moved nothing,
      // and the settle is re-seeded once per frame with its own clock
      // restarting each time. That is verbatim the spring `_continueSettle`'s
      // doc says it exists to prevent, in the one shape nothing drove it in:
      // the fallback is asserted directly and through `settleTo`, and was
      // asserted nowhere it was newly wired in.
      final model = newModel();
      model.applyLayout(_landscape);
      expect(model.detents.extentOf(Detent.medium), isNull);

      // 380 is on full's side of the surviving pair — the peek at 201 and full
      // at 402 — so "nearest to the panel" and "nearest to zero" are different
      // stops, 201pt apart. At 260 they would be the same one and this would
      // pass either way.
      model.applyExtent(const Extent(380));
      model.settleTo(Detent.medium);
      model.tick(const Duration(milliseconds: 16));

      final settling = model.activity as SettlingPanelActivity;
      expect(settling.destination, Detent.medium);
      expect(settling.to.px, 402.0);

      model.applyLayout(_landscape);
      model.applyLayout(_landscape);

      expect(model.activity, same(settling));
      expect(
        settling.elapsed,
        const Duration(milliseconds: 16),
        reason: 'two passes, and the settle is the one that was running',
      );
      expect(settling.motion.duration, const Duration(milliseconds: 500));
    });

    test('and a settle whose time is spent arrives, rather than parking '
        'short', () {
      // `remaining` reaching zero means the settle is over, and a settle that is
      // over is *at* its destination. Answering `current` there parked the panel
      // at a detent it had never moved to and nothing moved it afterwards: the
      // spring was replaced by an idle activity in the same commit, and every
      // pass after that resolved the detent the panel was already claimed to be
      // standing on. Measured here at 408pt of permanent error, and the window
      // is wide — a 500ms spring over this 342pt gap needs about 850ms to reach
      // half a physical pixel, so 40% of a settle's real life is spent in it.
      //
      // **The destination is `.medium`, and the layout it arrives into has not
      // got one.** Aimed at `.full` — which is how this row was first written —
      // the detent the settle was heading for and the nearest survivor to where
      // it lands are the same detent, so parking at either satisfies the
      // assertion and the arrival is free to record the fallback as though it
      // were the target. That is review 0's own P0 one level down: the fallback
      // moves the panel and must not rewrite the detent, or the rotation is a
      // one-way trip and turning the phone back leaves the sheet 342pt off.
      final model = newModel();
      model.applyExtent(peek);
      model.settleTo(Detent.medium);
      model.tick(const Duration(milliseconds: 600));

      final settling = model.activity as SettlingPanelActivity;
      expect(settling.remaining, Duration.zero);
      expect(
        settling.isDone,
        isFalse,
        reason: 'a spring is not finished when its nominal duration is',
      );
      expect(model.extent.px, lessThan(medium.px));

      final dry = model.dryApplyLayout(_landscape);
      model.applyLayout(_landscape);
      expect(model.extent.px, dry.px);
      expect(model.detents.extentOf(Detent.medium), isNull);
      expect(
        model.extent.px,
        402.0,
        reason: 'the nearest height a compact-height layout still has',
      );
      expect(model.activity, isA<IdlePanelActivity>());
      expect(
        (model.activity as IdlePanelActivity).target,
        Detent.medium,
        reason:
            'parked at the detent it was settling to, not at the one it had to '
            'borrow a height from — full is what nearestTo(402) answers, and '
            'recording it here is what makes the fallback permanent',
      );
      expect(model.isTicking, isFalse);

      model.applyLayout(portrait);
      expect(
        model.extent.px,
        closeTo(medium.px, 1e-9),
        reason:
            'so turning the phone back restores it, with nothing having had '
            'to remember anything',
      );
    });

    test('and a re-seeded settle keeps its own curve, not the config\'s', () {
      // "The same spring in less time and not a different one" was true only
      // when the running settle's spring happened to be the config's. The
      // duration is what a correction shortens; the bounce is the settle's own.
      final model = newModel();
      model.animateTo(Detent.full, motion: const PanelMotion.bouncy());
      model.tick(const Duration(milliseconds: 16));
      model.applyLayout(bigger);

      final settling = model.activity as SettlingPanelActivity;
      expect(settling.motion.duration, const Duration(milliseconds: 484));
      expect(
        settling.motion.bounce,
        const PanelMotion.bouncy().bounce,
        reason: 'the time ran out, not the spring',
      );
      expect(
        _config.motion.bounce,
        isNot(const PanelMotion.bouncy().bounce),
        reason: 'and the config would have answered differently',
      );
    });

    test('and the finger keeps the panel past the frame the resize was in', () {
      // Freezing the extent holds the pixels for exactly one pass: what the
      // panel shows is recomputed from the accumulated position against
      // whatever travel and whatever band are current, so the next sample — a
      // zero-pixel one will do — recomputes the whole gesture against the new
      // geometry. That is the yank the correction exists to prevent, one frame
      // late, and it is the largest one in the layer. `RubberBand.inverse` is
      // what recovers the position, and until now nothing called it.
      final model = newModel();
      final drag = DragPanelActivity(from: medium);
      model.beginActivity(drag);
      drag.update(400);

      final frozen = model.extent;
      expect(
        frozen.px,
        lessThan(drag.rawExtent),
        reason: 'held past full, through the band',
      );

      model.applyLayout(bigger);
      expect(model.extent.px, frozen.px, reason: 'frozen, as before');

      drag.update(0);
      expect(
        model.extent.px,
        closeTo(frozen.px, 1e-9),
        reason: 'a finger that moved no pixels moves the panel no pixels',
      );
      drag.update(10);
      expect(
        model.extent.px,
        closeTo(frozen.px + 10, 1e-9),
        reason: 'and the next one is 1:1, inside the travel it is now in',
      );
      expect(
        drag.rawOvershoot,
        0,
        reason:
            'so a release now is not damped by an overdrag the taller '
            'device does not have',
      );
    });

    test('and a pass that moved nothing does not move the position the '
        'gesture is', () {
      // The other half of the rebase, and the half a real render pass spends
      // all its time in: a layout is committed every frame and most of those
      // frames change no geometry. The accumulated un-resisted position is the
      // one quantity a gesture *is*, and recovering it from the displacement
      // means running the band backwards — so a pass that round-tripped it
      // when nothing had moved would spend the whole gesture accumulating the
      // rounding error of a function and its inverse.
      //
      // 500 passes is eight seconds of a held finger, which is an ordinary
      // gesture, and the assertion is exact equality because the claim is
      // exact: a no-op is a no-op, not a small number of ulps.
      final model = newModel();
      final drag = DragPanelActivity(from: full);
      model.beginActivity(drag);
      drag.update(0.3);

      final raw = drag.rawExtent;
      final shown = model.extent;
      expect(raw, full.px + 0.3);
      expect(
        shown.px,
        lessThan(raw),
        reason:
            'held inside the band, which is where the round trip is not '
            'the identity',
      );

      for (var pass = 0; pass < 500; pass++) {
        model.applyLayout(kIPhone17Pro.layout());
      }

      expect(drag.rawExtent, raw);
      expect(model.extent.px, shown.px);
    });

    test('and a drag is left holding the panel where the finger has it', () {
      final model = newModel();
      final drag = DragPanelActivity(from: medium);
      model.beginActivity(drag);
      drag.update(40);
      final frozen = model.extent;

      final dry = model.dryApplyLayout(bigger);
      model.applyLayout(bigger);
      expect(model.extent.px, dry.px);
      expect(model.extent.px, frozen.px);
      expect(model.activity, same(drag));
      expect(
        model.detents.extentOf(Detent.full)!.px,
        closeTo(894, 1e-9),
        reason: 'the set moved under it and the finger still has the panel',
      );
    });

    test('and a resize the band cannot reach back across is bounded, not '
        'thrown', () {
      // Recovering the accumulated position is `RubberBand.inverse`, whose
      // domain stops at one viewport because that is where `map` stops being
      // invertible. A viewport that shrinks below the displacement already on
      // screen puts the rebase outside it — about 1600pt of accumulated
      // overdrag followed by a rotation, which is not a gesture, but the
      // alternative to naming the bound is an assert firing from inside a
      // layout pass.
      final model = newModel();
      final drag = DragPanelActivity(from: full);
      model.beginActivity(drag);
      drag.update(1610);

      final frozen = model.extent;
      expect(
        frozen.px - full.px,
        greaterThan(402.0),
        reason:
            'past a whole '
            'landscape viewport of displacement',
      );

      expect(() => model.applyLayout(_landscape), returnsNormally);
      expect(model.extent.px, frozen.px, reason: 'the freeze still holds');

      drag.update(0);
      expect(model.extent.px.isNaN, isFalse);
      expect(
        model.extent.px,
        lessThan(402.0 + 402.0),
        reason:
            'the band asymptotes at one viewport, so this is the deepest '
            'position it has — the panel is taller than the screen it is now '
            'on either way',
      );
      expect(model.extent.px, greaterThan(800.0));
    });

    test('and a fling keeps its position and its own clock across it', () {
      final model = newModel();
      final scroll = _FakeScroll();
      model.beginActivity(
        ScrollBallisticActivity(
          position: scroll,
          velocity: const ExtentVelocity(1800),
          resnapWindow: kResnapWindow,
        ),
      );
      final before = model.extent;

      final dry = model.dryApplyLayout(bigger);
      model.applyLayout(bigger);
      expect(model.extent.px, dry.px);
      expect(
        model.extent.px,
        before.px,
        reason: 'the projection moved, not the panel',
      );

      final fling = model.activity as ScrollBallisticActivity;
      expect(
        fling.position,
        same(scroll),
        reason:
            'handing it to a self-driven settle would drop the one thing '
            'that makes it a fling across two things',
      );
      expect(fling.isResnapping, isTrue);
    });
  });

  group('the config is adopted, and only re-snaps when it changed', () {
    test('an equal config is not a change', () {
      // Read from the wrong end, G10 says a panel snaps on every rebuild: the
      // widget above hands over a freshly built config every frame, and if the
      // set compared unequal the panel would re-target every frame.
      final model = newModel();
      final sameAgain = PanelConfig(
        detents: DetentSet(const [_peek, Detent.medium, Detent.full]),
        initialDetent: Detent.medium,
      );
      expect(identical(sameAgain, model.config), isFalse);
      expect(sameAgain, model.config);

      var notifications = 0;
      model.addListener(() => notifications++);
      model.updateConfig(sameAgain);
      expect(notifications, 0);
      expect(model.activity, isA<IdlePanelActivity>());
    });

    test('and a page change settles to the nearest surviving detent', () {
      // DESIGN.md §5's worked example: the detail page swaps the detent set,
      // and the extent settles to the surviving stop nearest where the panel
      // is, under the panel's own spring rather than jumping.
      //
      // **The new set has two stops and the panel starts at neither**, which
      // is what makes the row an assertion about "nearest" at all. Written
      // against a one-detent set — which is how this was first written, and
      // how the two rows below it still are — nearest and smallest are the
      // same object and the sentence in the test name is unfalsifiable. iOS's
      // own documented fallback for an unknown selection *is* the smallest, so
      // it is exactly the wrong answer this has to be able to see: from full,
      // nearest is medium at 469.68 and smallest is the peek at 214, which is
      // a page change that collapses the sheet 255pt further than it should.
      final model = newModel();
      model.applyExtent(full);

      model.updateConfig(
        const PanelConfig(detents: DetentSet([_peek, Detent.medium])),
      );

      expect(model.detents.snaps.length, 2);
      expect(model.detents.extentOf(Detent.full), isNull);
      expect(model.activity, isA<SettlingPanelActivity>());
      final settling = model.activity as SettlingPanelActivity;
      expect(settling.destination, Detent.medium);
      expect(settling.to.px, closeTo(medium.px, 1e-9));
      expect(
        settling.to.px,
        isNot(closeTo(peek.px, 1e-9)),
        reason:
            'and the smallest is a different place, or the row proves '
            'nothing',
      );
      expect(
        model.extent.px,
        full.px,
        reason: 'it settles from where it was; it does not arrive instantly',
      );
      expect(settling.from.px, full.px);
    });

    test('and a set change that keeps the height where it is does not '
        'animate to it', () {
      // A spring with nothing to do never reports itself done, so installing
      // one would leave `isTicking` false with a settle still installed — a
      // panel that has stopped moving and is, formally, still moving, which no
      // driver would ever tick again.
      final model = newModel();
      model.updateConfig(
        const PanelConfig(detents: DetentSet([Detent.medium])),
      );

      expect(model.detents.snaps.length, 1);
      expect(model.activity, isA<IdlePanelActivity>());
      expect((model.activity as IdlePanelActivity).target, Detent.medium);
      expect(model.extent.px, closeTo(medium.px, 1e-9));
      expect(model.isTicking, isFalse);
    });

    test('and never over the top of a finger', () {
      final model = newModel();
      final drag = DragPanelActivity(from: medium);
      model.beginActivity(drag);

      model.updateConfig(const PanelConfig(detents: DetentSet([Detent.full])));
      expect(
        model.activity,
        same(drag),
        reason: 'the new set applies when the finger lets go',
      );
      expect(model.detents.snaps.length, 1);
    });

    test('and not on the next finger sample either', () {
      // Declining to re-target is not the same as keeping the panel. The travel
      // and the band are both read live off the model, so a config that changes
      // either moves the panel on the very next delta — here a rebuild that
      // changed no detent and no layout, only the band the overdrag is mapped
      // through.
      final model = newModel();
      final drag = DragPanelActivity(from: full);
      model.beginActivity(drag);
      drag.update(200);
      final frozen = model.extent;
      expect(frozen.px, greaterThan(full.px));

      model.updateConfig(
        const PanelConfig(
          detents: _sheet,
          initialDetent: Detent.medium,
          bandResistance: 0.9,
        ),
      );
      expect(model.activity, same(drag));
      expect(model.extent.px, frozen.px);

      drag.update(0);
      expect(
        model.extent.px,
        closeTo(frozen.px, 1e-9),
        reason: 'a stiffer band under the same finger is still the same pixels',
      );
    });

    test('and a config that changed no detent leaves a settle running', () {
      // G10's guard is the *set* changing, and its own arm says why: a page that
      // swaps a spring or a scroll policy has not moved the panel, and
      // re-targeting on it is the every-frame re-snap the config's value
      // equality exists to prevent, one level down.
      final model = newModel();
      model.settleTo(Detent.full);
      model.tick(const Duration(milliseconds: 100));
      final settling = model.activity as SettlingPanelActivity;

      model.updateConfig(
        const PanelConfig(
          detents: _sheet,
          initialDetent: Detent.medium,
          resnapWindow: Duration(milliseconds: 40),
        ),
      );

      expect(model.config.resnapWindow, const Duration(milliseconds: 40));
      expect(
        model.activity,
        same(settling),
        reason: 'the same settle, still heading for the same detent',
      );
      expect(settling.destination, Detent.full);
      expect(settling.elapsed, const Duration(milliseconds: 100));
    });

    test('and a fused fling keeps its landing, for the reason the correction '
        'arm gives', () {
      // `applyLayout`'s ResnapBallistic arm declines to re-run `snapTarget`
      // because that hands one gesture across two things to a settle that has
      // only one of them, and drops the position that made it one. Read through
      // `isUserDriven` alone — which a ballistic is not — this branch did
      // exactly that, on a change the fling can neither see nor survive.
      final model = newModel();
      final scroll = _FakeScroll();
      final fling = ScrollBallisticActivity(
        position: scroll,
        velocity: const ExtentVelocity(2000),
        resnapWindow: kResnapWindow,
      );
      model.beginActivity(fling);

      model.updateConfig(const PanelConfig(detents: DetentSet([Detent.full])));
      expect(model.detents.snaps.length, 1);
      expect(model.activity, same(fling));
      expect(
        (model.activity as ScrollBallisticActivity).position,
        same(scroll),
      );
    });

    test('and it notifies once for whichever of those it did', () {
      final resnapped = newModel();
      var notifications = 0;
      resnapped.addListener(() => notifications++);
      resnapped.updateConfig(
        const PanelConfig(detents: DetentSet([Detent.full])),
      );
      expect(resnapped.activity, isA<SettlingPanelActivity>());
      expect(
        notifications,
        1,
        reason: 'installing the settle and adopting the config are one event',
      );

      final untouched = newModel();
      notifications = 0;
      untouched.addListener(() => notifications++);
      untouched.updateConfig(
        const PanelConfig(
          detents: _sheet,
          initialDetent: Detent.medium,
          snapPolicy: SnapPolicy.stepwise,
        ),
      );
      expect(untouched.activity, isA<IdlePanelActivity>());
      expect(
        notifications,
        1,
        reason: 'and a policy swap that moved nothing is still a change',
      );
    });
  });

  group('the ways a panel is told to move', () {
    test('goIdle parks it', () {
      final model = newModel();
      model.goIdle(target: _peek);
      expect(model.activity, isA<IdlePanelActivity>());
      expect((model.activity as IdlePanelActivity).target, _peek);
    });

    test('goBallistic settles wherever the fling projects', () {
      final model = newModel();
      model.applyExtent(peek);

      model.goBallistic(const ExtentVelocity(3000));
      expect(
        (model.activity as SettlingPanelActivity).destination,
        Detent.full,
      );

      final gentle = newModel()..applyExtent(peek);
      gentle.goBallistic(const ExtentVelocity(400));
      expect(
        (gentle.activity as SettlingPanelActivity).destination,
        Detent.medium,
      );
    });

    test('and springs under the motion the config gave it', () {
      final model = newModel(
        config: const PanelConfig(
          detents: _sheet,
          initialDetent: _peek,
          motion: PanelMotion.bouncy(duration: Duration(milliseconds: 320)),
        ),
      );
      model.goBallistic(const ExtentVelocity(3000));
      expect(
        (model.activity as SettlingPanelActivity).motion,
        const PanelMotion.bouncy(duration: Duration(milliseconds: 320)),
        reason: 'a release under a panel\'s own spring, not under the default',
      );
    });

    test('and a release onto the detent it is already at is still a '
        'motion', () {
      // The overshoot and the return *are* the fling. A release at 2000 px/s
      // from the top detent projects past it, comes back to it, and the panel
      // that refused to settle because `to == extent` would have deleted the
      // whole gesture.
      final model = newModel();
      model.applyExtent(full);
      model.goBallistic(const ExtentVelocity(2000));
      expect(model.activity, isA<SettlingPanelActivity>());
      expect(model.isTicking, isTrue);
    });

    test('and a release too small to be a motion parks instead', () {
      // A spring that reports itself done at t = 0 is never ticked, and an
      // activity nothing ticks is one nothing ever ends: `isTicking` false with
      // a settle installed, which is the state this refusal exists to prevent.
      // `velocity == ExtentVelocity.zero` was one comparison too narrow by
      // exactly the width of the simulation's own velocity tolerance, and a
      // recogniser reports sub-pixel-per-second lifts routinely — a finger that
      // stops before it leaves.
      for (final seed in const [0.0, 0.05, 0.1, 0.16]) {
        final model = newModel();
        model.goBallistic(ExtentVelocity(seed));
        expect(model.activity, isA<IdlePanelActivity>(), reason: '$seed px/s');
        expect(model.isTicking, isFalse, reason: '$seed px/s');
        expect(
          (model.activity as IdlePanelActivity).target,
          Detent.medium,
          reason: '$seed px/s',
        );
      }

      final moving = newModel();
      moving.goBallistic(const ExtentVelocity(0.2));
      expect(
        moving.activity,
        isA<SettlingPanelActivity>(),
        reason:
            'and the other side of the threshold is a motion — half a '
            'physical pixel a second, on this display',
      );
      expect(moving.isTicking, isTrue);
    });

    test('and honours the snap policy it was configured with', () {
      // The policy is not decoration: the same release goes two different
      // places, and the call site chose which.
      final stepwise = newModel(
        config: const PanelConfig(
          detents: _sheet,
          initialDetent: _peek,
          snapPolicy: SnapPolicy.stepwise,
        ),
      );
      stepwise.goBallistic(const ExtentVelocity(3000));
      expect(
        (stepwise.activity as SettlingPanelActivity).destination,
        Detent.medium,
      );
    });

    test('settleTo continues whatever was already moving', () {
      final model = newModel();
      model.beginActivity(
        SettlingPanelActivity(
          destination: Detent.full,
          from: medium,
          to: full,
          velocity: const ExtentVelocity(900),
          motion: const PanelMotion.smooth(),
        ),
      );

      model.settleTo(_peek);
      final settling = model.activity as SettlingPanelActivity;
      expect(settling.destination, _peek);
      expect(
        settling.velocity.pxPerSecond,
        closeTo(900, 1e-6),
        reason: 'a settle over a settle picks the motion up, not from rest',
      );
    });

    test('and `within` shortens the spring without changing its shape', () {
      // This is what a SettleWithin correction commits, and why re-seeding
      // converges: the bounce is the panel's, the duration is what was left.
      final model = newModel();
      model.settleTo(Detent.full, within: const Duration(milliseconds: 120));
      final settling = model.activity as SettlingPanelActivity;
      expect(settling.motion.duration, const Duration(milliseconds: 120));
      expect(settling.motion.bounce, _config.motion.bounce);
    });

    test('animateTo starts from rest', () {
      final model = newModel();
      model.animateTo(Detent.full);
      final settling = model.activity as SettlingPanelActivity;
      expect(settling.destination, Detent.full);
      expect(settling.velocity, ExtentVelocity.zero);
      expect(settling.motion, _config.motion);
    });

    test('and from rest even over something that was already moving', () {
      // The documented difference from `settleTo`, which a fresh model cannot
      // show: its idle activity reports zero either way, so both entry points
      // look identical until something is running under them.
      final model = newModel();
      model.beginActivity(
        SettlingPanelActivity(
          destination: Detent.full,
          from: medium,
          to: full,
          velocity: const ExtentVelocity(900),
          motion: const PanelMotion.smooth(),
        ),
      );

      model.animateTo(_peek);
      expect(
        (model.activity as SettlingPanelActivity).velocity,
        ExtentVelocity.zero,
        reason:
            'the programmatic entry point starts the panel, not continues '
            'it',
      );
    });

    test('and a settle with less than a millisecond left is an arrival', () {
      // `SpringDescription.withDurationAndBounce` measures whole milliseconds
      // and asserts above zero, so the guard has to be the band and not the
      // point: at 500µs, debug throws from inside a layout pass and release
      // truncates to a zero-second spring — infinite stiffness, a NaN extent
      // every frame, `isTicking` stuck true for the life of the panel.
      for (final within in const [
        Duration.zero,
        Duration(microseconds: 1),
        Duration(microseconds: 500),
        Duration(microseconds: 999),
      ]) {
        final model = newModel();
        model.settleTo(Detent.full, within: within);
        expect(model.activity, isA<IdlePanelActivity>(), reason: '$within');
        expect(
          (model.activity as IdlePanelActivity).target,
          Detent.full,
          reason: '$within',
        );
        expect(model.extent.px.isNaN, isFalse, reason: '$within');
        expect(model.isTicking, isFalse, reason: '$within');
      }

      final shortest = newModel();
      shortest.settleTo(Detent.full, within: kMinimumSettleDuration);
      expect(
        shortest.activity,
        isA<SettlingPanelActivity>(),
        reason: 'one millisecond is the shortest spring there is, and it runs',
      );
    });

    test('and stops at half a physical pixel of the display it is on', () {
      // Every device fixture in this package is a 3x display, and so is every
      // hand-built landscape layout, which makes `0.5 / devicePixelRatio` and
      // the hand-built `kSettleTolerance` the same number in every test that
      // exists. This is the one that tells them apart.
      final model = newModel();
      model.settleTo(Detent.full);
      expect(
        (model.activity as SettlingPanelActivity).tolerance,
        closeTo(0.5 / 3, 1e-12),
      );

      final coarse = PanelModel(config: _config, layout: _lowDensity);
      coarse.settleTo(Detent.full);
      expect(
        (coarse.activity as SettlingPanelActivity).tolerance,
        0.5,
        reason:
            'the layout it is on, not the one an uninstalled settle guesses',
      );
    });

    test('and takes a motion of its own when it is given one', () {
      final model = newModel();
      model.animateTo(_peek, motion: const PanelMotion.bouncy());
      expect(
        (model.activity as SettlingPanelActivity).motion,
        const PanelMotion.bouncy(),
      );
    });

    test('and settling where the panel already is parks it', () {
      // Same reason as the set change above: a spring from a place to itself,
      // at rest, is done at t = 0 and so is never ticked, and a settle nothing
      // ticks is a settle nothing ever ends.
      final model = newModel();
      model.settleTo(Detent.medium);
      expect(model.activity, isA<IdlePanelActivity>());
      expect((model.activity as IdlePanelActivity).target, Detent.medium);
      expect(model.isTicking, isFalse);
    });

    test('and settling at a detent the set no longer has takes the nearest '
        'height without forgetting the detent', () {
      // The same fallback `LayoutCorrection.hold` makes: the panel moves the
      // shortest distance it can, and the target is not rewritten, so a
      // rotation back restores it. Asserted from both sides of the surviving
      // pair — 201 and 402 — because one side alone cannot tell "nearest" from
      // "smallest", and iOS's documented fallback for an unknown *selection* is
      // the smallest.
      SettlingPanelActivity settlingFrom(Extent start) {
        final model = newModel();
        model.applyLayout(_landscape);
        expect(model.detents.extentOf(Detent.medium), isNull);
        model.applyExtent(start);
        model.settleTo(Detent.medium);
        final settling = model.activity as SettlingPanelActivity;
        expect(
          settling.destination,
          Detent.medium,
          reason: 'it is the detent that left, not the panel',
        );
        return settling;
      }

      expect(settlingFrom(const Extent(260)).to.px, 201.0);
      expect(settlingFrom(const Extent(380)).to.px, 402.0);
    });
  });

  group('the config is a value, because it is handed over every frame', () {
    test('so an equal one hashes equal', () {
      const config = PanelConfig(detents: _sheet, initialDetent: Detent.medium);
      final rebuilt = PanelConfig(
        detents: DetentSet(const [_peek, Detent.medium, Detent.full]),
        initialDetent: Detent.medium,
      );
      expect(identical(config, rebuilt), isFalse);
      expect(rebuilt.hashCode, config.hashCode);
      expect(<PanelConfig>{config, rebuilt}, hasLength(1));
    });

    test('and every field it carries can tell two configs apart', () {
      const base = PanelConfig(detents: _sheet);
      expect(base, isNot(const PanelConfig(detents: DetentSet([Detent.full]))));
      expect(
        base,
        isNot(const PanelConfig(detents: _sheet, initialDetent: Detent.full)),
      );
      expect(
        base,
        isNot(
          const PanelConfig(detents: _sheet, snapPolicy: SnapPolicy.stepwise),
        ),
      );
      expect(
        base,
        isNot(const PanelConfig(detents: _sheet, motion: PanelMotion.bouncy())),
      );
      expect(
        base,
        isNot(const PanelConfig(detents: _sheet, resnapWindow: Duration.zero)),
      );
      expect(
        base,
        isNot(const PanelConfig(detents: _sheet, bandResistance: 0.4)),
      );
    });

    test('and says what it is, policies included', () {
      expect(
        const PanelConfig(detents: DetentSet([Detent.full])).toString(),
        allOf(
          startsWith('PanelConfig(DetentSet([Detent.full])'),
          contains('snapPolicy: projected'),
          contains('resnapWindow: 0:00:00.150000'),
          contains('bandResistance: 0.55'),
        ),
      );
    });
  });

  group('the extent has one writer', () {
    test('and it notifies exactly when the panel moved', () {
      final model = newModel();
      var notifications = 0;
      model.addListener(() => notifications++);

      model.applyExtent(const Extent(500));
      expect(model.extent.px, 500.0);
      expect(notifications, 1);

      model.applyExtent(const Extent(500));
      expect(
        notifications,
        1,
        reason: 'a spring that has settled writes its destination every frame',
      );
    });

    test('and a tick goes to the current activity and nowhere else', () {
      final model = newModel();
      final before = model.extent;
      model.tick(const Duration(milliseconds: 16));
      expect(model.extent.px, before.px, reason: 'an idle panel ignores time');
    });

    test('and it is handed on even to an activity that has stopped wanting '
        'frames', () {
      // The cost of the `isTicking` guard `tick` used to have, and the reason
      // it is gone: an activity that does not want frames is not the same as
      // an activity with nothing left to do. A settle installed with its spring
      // already finished — `beginActivity` is public, and the scroll layer
      // hands activities over directly — is the panel's whole state, and the
      // frame it parks the panel in is a frame the guard refused to give it.
      // It never asks for another one either, so nothing else ever arrives:
      // `isTicking` is false with a settle installed, which is the terminal
      // state the rest of this layer is shaped to prevent.
      final model = newModel();
      final finished = SettlingPanelActivity(
        destination: Detent.full,
        from: full,
        to: full,
        velocity: ExtentVelocity.zero,
        motion: const PanelMotion.smooth(),
      );
      expect(finished.isTicking, isFalse);

      model.beginActivity(finished);
      expect(model.isTicking, isFalse);

      model.tick(const Duration(milliseconds: 16));
      expect(
        model.activity,
        isA<IdlePanelActivity>(),
        reason: 'the frame it hands the panel on in',
      );
      expect((model.activity as IdlePanelActivity).target, Detent.full);
      expect(model.extent.px, full.px);
    });
  });

  group('one event, one notification', () {
    // Every listener here is a widget rebuild, and a rebuild in the middle of
    // the frame something else is already reacting to is the cost. `_begin`'s
    // `notify` parameter exists for exactly this, and the tests below are what
    // keep it used.

    test('installing an activity is one', () {
      final model = newModel();
      var notifications = 0;
      model.addListener(() => notifications++);
      model.beginActivity(DragPanelActivity(from: medium));
      expect(
        notifications,
        1,
        reason: 'isUserDriven and isTicking both changed for anything watching',
      );
    });

    test('and a layout pass that re-seeds a settle is one', () {
      final model = newModel();
      model.settleTo(Detent.full);
      model.tick(const Duration(milliseconds: 100));

      var notifications = 0;
      model.addListener(() => notifications++);
      model.applyLayout(bigger);
      expect(model.activity, isA<SettlingPanelActivity>());
      expect(
        notifications,
        1,
        reason: 'the commit installs an activity partway through one change',
      );
    });

    test('and parking the panel programmatically is one', () {
      // `goIdle` is public and documented, and it is the one path in this group
      // that moves nothing: parking deliberately leaves the extent alone and
      // lets the next layout pass say where the detent is. So the activity
      // change is the whole event, and the notification is the only way anybody
      // hears about it — the route watching `isUserDriven`, the barrier, and
      // above all whatever owns the ticker and reads `isTicking` to know when
      // to stop asking for frames.
      final model = newModel();
      model.settleTo(Detent.full);
      expect(model.isTicking, isTrue);

      var notifications = 0;
      model.addListener(() => notifications++);

      model.goIdle(target: Detent.medium);
      expect(model.activity, isA<IdlePanelActivity>());
      expect(
        notifications,
        1,
        reason: 'a panel parked without a word leaves its ticker running',
      );
      expect(model.isTicking, isFalse);
    });

    test('and so is a settle finishing where the panel already stands', () {
      // The narrow clause of the commit's notification test — the one that is
      // not about movement. Here the layout did not change, the detents did
      // not change, and the panel is already standing on the destination, so
      // every clause of `moved` is false; the only thing this pass does is
      // replace the settle with an idle. Judged on movement alone it would say
      // nothing, and the driver would never be told the settle it is spending
      // frames on is over.
      final model = newModel();
      model.settleTo(Detent.full);
      model.tick(const Duration(milliseconds: 600));
      model.applyExtent(full);
      expect(model.isTicking, isTrue, reason: 'the settle is still installed');

      var notifications = 0;
      model.addListener(() => notifications++);

      final same = kIPhone17Pro.layout();
      expect(same, model.layout);
      model.applyLayout(same);

      expect(model.extent.px, full.px, reason: 'and nothing moved');
      expect(model.activity, isA<IdlePanelActivity>());
      expect(model.isTicking, isFalse);
      expect(notifications, 1);
    });

    test('and the frame a settle arrives in is one, like every frame before '
        'it', () {
      // `applyExtent` followed by `goIdle` is two notifications for one event,
      // and the frame it happens in is the frame a route, a barrier and a
      // scroll link are all already reacting to.
      final model = newModel();
      model.settleTo(Detent.full);

      var notifications = 0;
      model.addListener(() => notifications++);

      final perFrame = <int>[];
      while (model.isTicking && perFrame.length < 200) {
        notifications = 0;
        model.tick(const Duration(milliseconds: 16));
        perFrame.add(notifications);
      }

      expect(model.activity, isA<IdlePanelActivity>());
      expect(perFrame.last, 1, reason: 'the frame it parked in');
      expect(perFrame, everyElement(lessThanOrEqualTo(1)));
    });
  });

  group('the exit velocity is consumed once', () {
    test('so a later programmatic pop cannot inherit a stale fling', () {
      final model = newModel();
      expect(model.takeExitVelocity(), ExtentVelocity.zero);

      model.stashExitVelocity(const ExtentVelocity(-2400));
      expect(model.takeExitVelocity().pxPerSecond, -2400.0);
      expect(
        model.takeExitVelocity(),
        ExtentVelocity.zero,
        reason: 'the read is what clears it',
      );
    });
  });
}
