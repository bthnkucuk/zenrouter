import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/model/correction.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/physics/motion.dart';
import 'package:shits/src/physics/rubber_band.dart';

import '../fixtures/devices.dart';

// ============================================================================
// What each leaf does between layout passes: who owns it, what moves it, and
// what it leaves behind. `correction_test.dart` covers what a leaf answers when
// the geometry changes underneath it; this file covers the rest of its life.
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

void main() {
  final portrait = kIPhone17Pro.layout();
  final detents = _sheet.resolve(portrait.baseline);
  final peek = detents.extentOf(_peek)!;
  final medium = detents.extentOf(Detent.medium)!;
  final full = detents.extentOf(Detent.full)!;

  /// The band the model is expected to use: normalised to the **viewport**,
  /// which is 874 here, and not to the 778pt detent baseline. Built from the
  /// same two numbers the model has, so a test failure means the model chose a
  /// different normaliser rather than that this line has a stale constant.
  final band = RubberBand(viewport: portrait.baseline.viewportSpan);

  PanelModel newModel({PanelConfig config = _config}) =>
      PanelModel(config: config, layout: portrait);

  group('an activity belongs to exactly one model', () {
    test('and has no owner until it is installed', () {
      // `isA<Error>()` is what this asked for first, and a bare `_owner!` (a
      // `TypeError`) satisfies it exactly as well as the refusal does — so the
      // four lines that are the entire content of the getter were unpinned, and
      // a consumer reading `owner` early would have been told "Null check
      // operator used on a null value" instead of which binding has not
      // happened yet.
      final idle = IdlePanelActivity(target: Detent.medium);
      expect(
        () => idle.owner,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('has not been installed'),
              contains('beginActivity'),
            ),
          ),
        ),
        reason: 'building a settle before installing it is how a fling reads',
      );

      final model = newModel();
      model.beginActivity(idle);
      expect(idle.owner, same(model));
      expect(model.activity, same(idle));
    });

    test('and only the installed one is ticked', () {
      // The observable half of "beginActivity disposes the outgoing activity":
      // a replaced settle stops receiving time, so it cannot keep writing the
      // extent behind the activity that replaced it.
      final model = newModel();
      final settling = SettlingPanelActivity(
        destination: Detent.full,
        from: medium,
        to: full,
        velocity: ExtentVelocity.zero,
        motion: const PanelMotion.smooth(),
      );
      model.beginActivity(settling);
      model.beginActivity(IdlePanelActivity(target: Detent.medium));

      final before = model.extent;
      model.tick(const Duration(milliseconds: 100));
      expect(settling.elapsed, Duration.zero);
      expect(model.extent.px, before.px);
    });

    test('and the model ends the outgoing one when it installs the next', () {
      // The seam the scroll layer's `absorb` lands on. Every leaf currently
      // holds nothing, so a `dispose` that was never called looks exactly like
      // one that was — both of the two calls that make an activity's lifetime a
      // lifetime could be deleted and nothing else in the package would notice.
      final model = newModel();
      final outgoing = DragPanelActivity(from: medium);
      model.beginActivity(outgoing);
      expect(outgoing.isDisposed, isFalse);

      model.beginActivity(IdlePanelActivity(target: Detent.medium));
      expect(outgoing.isDisposed, isTrue);
      expect(model.activity.isDisposed, isFalse);
    });

    test('and disposing the model disposes it', () {
      final model = newModel();
      final activity = model.activity;
      expect(model.dispose, returnsNormally);
      expect(
        activity.isDisposed,
        isTrue,
        reason:
            'an activity that outlived its model would tick into a '
            'disposed notifier',
      );
    });
  });

  group('the two branches', () {
    test('a self-driven activity has no position to be null', () {
      expect(
        IdlePanelActivity(target: Detent.medium),
        isA<SelfDrivenActivity>(),
      );
      expect(DragPanelActivity(from: medium), isA<SelfDrivenActivity>());
      expect(
        DragPanelActivity(from: medium),
        isNot(isA<ScrollDrivenActivity>()),
      );
    });

    test('and a scroll-driven one always has one', () {
      final scroll = _FakeScroll()..pixels = 120;
      final drag = ScrollDragActivity(position: scroll, from: medium);
      expect(drag, isA<ScrollDrivenActivity>());
      expect(drag, isNot(isA<SelfDrivenActivity>()));
      expect(drag.position, same(scroll));
      expect(drag.position.pixels, 120);
      expect(drag.position.minScrollExtent, 0);
    });
  });

  group('idle', () {
    test('is not moving and does not want frames', () {
      final idle = IdlePanelActivity(target: Detent.medium);
      expect(idle.target, Detent.medium);
      expect(idle.velocity, ExtentVelocity.zero);
      expect(idle.isUserDriven, isFalse);
      expect(idle.isTicking, isFalse);
    });

    test('and a tick moves nothing', () {
      final model = newModel();
      final idle = IdlePanelActivity(target: Detent.medium);
      model.beginActivity(idle);
      final before = model.extent;
      model.tick(const Duration(milliseconds: 100));
      expect(model.extent.px, before.px);
      expect(model.activity, same(idle));
    });
  });

  group('a drag', () {
    ({PanelModel model, DragPanelActivity drag}) dragging(Extent from) {
      final model = newModel();
      final drag = DragPanelActivity(from: from);
      model.beginActivity(drag);
      return (model: model, drag: drag);
    }

    test('moves the panel 1:1 inside the travel', () {
      final (:model, :drag) = dragging(medium);
      drag.update(50);
      expect(model.extent.px, closeTo(medium.px + 50, 1e-9));
      drag.update(-20);
      expect(model.extent.px, closeTo(medium.px + 30, 1e-9));
      expect(drag.rawOvershoot, 0);
    });

    test('and reports zero velocity until the finger leaves', () {
      final (:model, :drag) = dragging(medium);
      drag.update(50);
      expect(
        drag.velocity,
        ExtentVelocity.zero,
        reason: 'the speed is the recogniser\'s estimate and arrives at end()',
      );
      expect(drag.isUserDriven, isTrue);
      expect(drag.isTicking, isFalse);
      expect(model.isTicking, isFalse);
    });

    test('and rubber-bands above the tallest detent', () {
      final (:model, :drag) = dragging(full);
      drag.update(100);
      expect(drag.rawExtent, closeTo(full.px + 100, 1e-9));
      expect(drag.rawOvershoot, closeTo(100, 1e-9));
      expect(model.extent.px, closeTo(full.px + band.map(100).px, 1e-9));
      expect(
        model.extent.px,
        lessThan(full.px + 100),
        reason: 'the band resists, so the panel lags the finger',
      );
    });

    test('and engages at the first pixel past it, not a pixel later', () {
      // Every other band assertion in this package — here, on the scroll
      // branch, and in `rubber_band_test.dart` — drags 100 or 120pt past a
      // detent, which is a hundred pixels away from the only place the band
      // can be wrong about where it *starts*. A dead band one pixel wide at
      // the top of the travel is invisible at 100pt and plainly visible at
      // one: the panel tracks the finger 1:1 to the end of the dead band and
      // then steps **backwards** by ~0.45pt as the band takes over, which is a
      // hitch at the exact moment the resistance is supposed to begin.
      //
      // So this samples the corner itself, and asserts three things about it —
      // the panel is already resisted at a thousandth of a pixel, the
      // displacement is the band's own curve there, and the shown extent never
      // goes backwards while the finger goes forwards.
      double shownAt(double overdrag) {
        final (:model, :drag) = dragging(full);
        drag.update(overdrag);
        expect(
          drag.rawOvershoot,
          closeTo(overdrag, 1e-12),
          reason: 'the accumulated overshoot at $overdrag pt',
        );
        return model.extent.px;
      }

      var previous = full.px;
      for (final overdrag in const [0.001, 0.5, 1.0, 1.001, 2.0]) {
        final shown = shownAt(overdrag);
        expect(
          shown,
          closeTo(full.px + band.map(overdrag).px, 1e-12),
          reason: 'the band\'s own curve at $overdrag pt',
        );
        expect(
          shown,
          lessThan(full.px + overdrag),
          reason: 'resisted from the first pixel, not tracked 1:1 at $overdrag',
        );
        expect(
          shown,
          greaterThan(previous),
          reason: 'and never steps backwards as the band takes over',
        );
        previous = shown;
      }
    });

    test('and below the smallest one, since nothing may be dismissed yet', () {
      final (:model, :drag) = dragging(peek);
      drag.update(-100);
      expect(detents.dismissible, isFalse);
      expect(model.extent.px, closeTo(peek.px - band.map(100).px, 1e-9));
    });

    test('and the band is path-independent', () {
      // 100 deltas of one pixel land where one delta of a hundred lands.
      // Integrating resisted fragments does not — the same gesture then ends
      // somewhere different at a different frame rate.
      Extent draggedBy(List<double> deltas) {
        final (:model, :drag) = dragging(full);
        for (final delta in deltas) {
          drag.update(delta);
        }
        return model.extent;
      }

      expect(
        draggedBy(const [100.0]).px,
        closeTo(draggedBy(List<double>.filled(100, 1.0)).px, 1e-9),
      );
    });

    test('and coming back out of an overdrag resumes 1:1', () {
      // The accumulated position is the un-resisted one, so returning does not
      // resume from a resisted height and compound the resistance.
      final (:model, :drag) = dragging(full);
      drag.update(100);
      drag.update(-100);
      expect(drag.rawOvershoot, 0);
      expect(model.extent.px, closeTo(full.px, 1e-9));
    });

    test('and ending it sends the panel where the fling projects', () {
      final (:model, :drag) = dragging(peek);
      drag.end(const ExtentVelocity(3000));
      expect(model.activity, isA<SettlingPanelActivity>());
      final settling = model.activity as SettlingPanelActivity;
      expect(
        settling.destination,
        Detent.full,
        reason: 'a hard fling crosses as many detents as it paid for',
      );
      expect(
        settling.velocity.pxPerSecond,
        closeTo(3000, 1e-6),
        reason: 'the release is seeded verbatim, never zeroed',
      );
    });

    test('and cancelling it settles at the nearest detent, from rest', () {
      final (:model, :drag) = dragging(medium);
      drag.update(30);
      drag.cancel();
      expect(model.activity, isA<SettlingPanelActivity>());
      final settling = model.activity as SettlingPanelActivity;
      expect(settling.destination, Detent.medium);
      expect(settling.velocity, ExtentVelocity.zero);
    });

    test('and the band it is resisted by is the config\'s, at both ends of '
        'the policy', () {
      // A5: a policy is only worth the name if both ends are tested, and a
      // default nobody has tried the other side of is a hardcoded choice with
      // extra steps. This one has no other call site — the band is built per
      // gesture from a viewport the model measures — so the config is the only
      // way an author reaches it, and every other drag expectation in this file
      // is built at the default.
      final shown = <double, double>{};
      for (final resistance in const [0.2, 0.9]) {
        final model = newModel(
          config: PanelConfig(
            detents: _sheet,
            initialDetent: Detent.medium,
            bandResistance: resistance,
          ),
        );
        final drag = DragPanelActivity(from: full);
        model.beginActivity(drag);
        drag.update(100);

        final expected = RubberBand(
          viewport: portrait.baseline.viewportSpan,
          c: resistance,
        );
        expect(
          model.extent.px,
          closeTo(full.px + expected.map(100).px, 1e-9),
          reason: 'c = $resistance',
        );
        shown[resistance] = model.extent.px;
      }
      expect(
        shown[0.2],
        lessThan(shown[0.9]!),
        reason:
            'and the two ends are different places, or the row proves '
            'nothing',
      );
    });

    test('and a release from inside the band leaves at the speed the panel '
        'was moving, not the speed the finger was', () {
      // The band means the pixels under the finger are moving slower than the
      // finger is — by exactly `slope`, which is the derivative of the same
      // curve `map` applied on the way in. Projecting the finger's own speed
      // would fling the panel as though it had been keeping up with the hand
      // the whole way out.
      final (:model, :drag) = dragging(full);
      drag.update(120);
      final scale = band.slope(120);
      expect(scale, lessThan(1));

      drag.end(const ExtentVelocity(2000));
      final settling = model.activity as SettlingPanelActivity;
      expect(settling.velocity.pxPerSecond, closeTo(2000 * scale, 1e-6));
      expect(
        settling.destination,
        Detent.full,
        reason:
            'a release inside the band comes back to the stop it was '
            'pulled past',
      );
    });
  });

  group('the leaves a finger drives take no time', () {
    test('so a tick handed to one directly moves nothing', () {
      // `PanelModel.tick` never reaches these — it asks `isTicking` first — so
      // "ignores the delta" is only a claim until it is asked here.
      final leaves = <PanelActivity>[
        IdlePanelActivity(target: Detent.medium),
        DragPanelActivity(from: medium),
        ScrollDragActivity(position: _FakeScroll(), from: medium),
      ];
      for (final leaf in leaves) {
        expect(leaf.isTicking, isFalse, reason: '${leaf.runtimeType}');
        leaf.tick(const Duration(milliseconds: 16));
        expect(
          leaf.velocity,
          ExtentVelocity.zero,
          reason: '${leaf.runtimeType} moved under a clock it does not keep',
        );
      }
    });
  });

  group('a scroll-driven drag does the same arithmetic', () {
    test('and is the same 1:1 inside the travel', () {
      final model = newModel();
      final drag = ScrollDragActivity(position: _FakeScroll(), from: medium);
      model.beginActivity(drag);
      drag.update(50);
      expect(model.extent.px, closeTo(medium.px + 50, 1e-9));
      expect(drag.rawOvershoot, 0);
      expect(drag.isUserDriven, isTrue);
      expect(drag.isTicking, isFalse);
    });

    test('and the same band above the top detent', () {
      final model = newModel();
      final drag = ScrollDragActivity(position: _FakeScroll(), from: full);
      model.beginActivity(drag);
      drag.update(100);
      expect(model.extent.px, closeTo(full.px + band.map(100).px, 1e-9));
    });

    test('and keeps the same un-resisted position on the way back out', () {
      final model = newModel();
      final drag = ScrollDragActivity(position: _FakeScroll(), from: full);
      model.beginActivity(drag);

      drag.update(100);
      expect(drag.rawExtent, closeTo(full.px + 100, 1e-9));
      expect(drag.rawOvershoot, closeTo(100, 1e-9));

      drag.update(-100);
      expect(drag.rawExtent, closeTo(full.px, 1e-9));
      expect(drag.rawOvershoot, 0);
      expect(model.extent.px, closeTo(full.px, 1e-9));
    });

    test('and ending it goes ballistic on the fused axis', () {
      // The window is deliberately not the default, because the default is
      // `kResnapWindow` and a hard-coded one would pass against it.
      final model = newModel(
        config: const PanelConfig(
          detents: _sheet,
          initialDetent: Detent.medium,
          resnapWindow: Duration(milliseconds: 40),
        ),
      );
      final scroll = _FakeScroll();
      final drag = ScrollDragActivity(position: scroll, from: medium);
      model.beginActivity(drag);
      drag.end(const ExtentVelocity(2000));

      final fling = model.activity as ScrollBallisticActivity;
      expect(
        fling.position,
        same(scroll),
        reason: 'the fling keeps the position it was handed off from',
      );
      expect(
        fling.resnapWindow,
        const Duration(milliseconds: 40),
        reason: 'the window is the panel\'s policy, not the activity\'s',
      );
      expect(
        fling.velocity.pxPerSecond,
        closeTo(2000, 1e-6),
        reason: 'and the throw crosses the seam with it',
      );
    });

    test('and the release is scaled by the band it was pulled through', () {
      // The half of the handoff nothing checked. This branch does the
      // self-driven branch's arithmetic on the other side of the hierarchy,
      // which is exactly the duplication that goes wrong quietly: the panel
      // would feel one way dragged by the handle and another dragged by the
      // list, and nobody reports that as a bug.
      final model = newModel();
      final drag = ScrollDragActivity(position: _FakeScroll(), from: full);
      model.beginActivity(drag);
      drag.update(120);

      final scale = band.slope(120);
      expect(scale, lessThan(1));

      drag.end(const ExtentVelocity(2000));
      expect(
        (model.activity as ScrollBallisticActivity).velocity.pxPerSecond,
        closeTo(2000 * scale, 1e-6),
      );
    });

    test('and the geometry moving under it does not move the pixels, this '
        'frame or the next', () {
      // The same rebase the self-driven drag gets, through the same body —
      // `PanelDragMechanics` is one implementation because a band applied one
      // way on one branch and another way on the other is the bug this
      // hierarchy is otherwise shaped to invite.
      final model = newModel();
      final drag = ScrollDragActivity(position: _FakeScroll(), from: medium);
      model.beginActivity(drag);
      drag.update(400);
      final frozen = model.extent;

      model.applyLayout(kIPhone17ProMax.layout());
      expect(model.extent.px, frozen.px);
      drag.update(0);
      expect(model.extent.px, closeTo(frozen.px, 1e-9));
    });

    test('and cancelling it settles the panel and leaves the list where it '
        'was', () {
      // There is no throw to carry across the seam, so there is nothing to
      // fuse: the panel comes back on its own and the list keeps its offset.
      final model = newModel();
      final scroll = _FakeScroll()..pixels = 300;
      final drag = ScrollDragActivity(position: scroll, from: medium);
      model.beginActivity(drag);
      drag.update(30);
      drag.cancel();

      final settling = model.activity as SettlingPanelActivity;
      expect(settling.destination, Detent.medium);
      expect(settling.velocity, ExtentVelocity.zero);
      expect(scroll.pixels, 300);
    });
  });

  group('a settle', () {
    SettlingPanelActivity settleTo(
      Detent destination,
      Extent to, {
      ExtentVelocity velocity = ExtentVelocity.zero,
      PanelMotion motion = const PanelMotion.smooth(),
    }) => SettlingPanelActivity(
      destination: destination,
      from: medium,
      to: to,
      velocity: velocity,
      motion: motion,
    );

    test('starts at the velocity it was handed', () {
      final settling = settleTo(
        Detent.full,
        full,
        velocity: const ExtentVelocity(600),
      );
      expect(settling.elapsed, Duration.zero);
      expect(settling.velocity.pxPerSecond, closeTo(600, 1e-6));
      expect(settling.isDone, isFalse);
      expect(settling.isTicking, isTrue);
      expect(settling.isUserDriven, isFalse);
    });

    test('even when that velocity points away from where it is going', () {
      // A finger still travelling up when the projection has already chosen a
      // lower detent is a real gesture. `smooth_sheets` substitutes zero there
      // (`lib/src/physics.dart:114-118`) and starts the spring from rest at the
      // moment the user was moving fastest.
      final settling = settleTo(
        _peek,
        peek,
        velocity: const ExtentVelocity(1200),
      );
      expect(settling.to.px, lessThan(settling.from.px));
      expect(settling.velocity.pxPerSecond, closeTo(1200, 1e-6));
    });

    test('moves the extent as it is ticked', () {
      final model = newModel();
      final settling = settleTo(Detent.full, full);
      model.beginActivity(settling);
      expect(model.isTicking, isTrue);

      model.tick(const Duration(milliseconds: 16));
      expect(settling.elapsed, const Duration(milliseconds: 16));
      expect(model.extent.px, greaterThan(medium.px));
      expect(model.extent.px, lessThan(full.px));
    });

    test('and parks at its destination when it is done', () {
      final model = newModel();
      final settling = settleTo(Detent.full, full);
      model.beginActivity(settling);

      for (var frame = 0; frame < 200 && model.isTicking; frame++) {
        model.tick(const Duration(milliseconds: 16));
      }

      expect(settling.isDone, isTrue);
      expect(model.activity, isA<IdlePanelActivity>());
      expect((model.activity as IdlePanelActivity).target, Detent.full);
      expect(
        model.extent.isCloseTo(full, devicePixelRatio: 3),
        isTrue,
        reason:
            'settled to within half a physical pixel, which is all a '
            'display can show',
      );
      expect(
        model.extent.px,
        full.px,
        reason:
            'and exactly at it, not at the simulation\'s own last sample — a '
            'panel parked at a detent should be at the height the next hold '
            'resolves to, with no sub-pixel step between arriving and being '
            'told where it arrived. isDone already guarantees the row above.',
      );
    });

    test('and a spring of less than a millisecond is refused where it is '
        'built', () {
      // The model parks instead of asking for one, and this is the other end of
      // that: the type that would hand the panel a NaN says so itself, and says
      // which failure it is preventing rather than leaving the SDK to answer
      // "Duration must be positive" from four frames deeper.
      expect(
        () => SettlingPanelActivity(
          destination: Detent.full,
          from: medium,
          to: full,
          velocity: ExtentVelocity.zero,
          motion: const PanelMotion(duration: Duration(microseconds: 500)),
        ),
        throwsA(
          isA<AssertionError>().having(
            (error) => error.message,
            'message',
            contains('is not a motion'),
          ),
        ),
      );
    });

    test('and one built by hand stops at half a pixel of the finest display '
        'in common use', () {
      // The default only applies to a settle that has nobody to ask — an
      // activity is built before it is installed, which is how a fling reads —
      // and `PanelModel` always overrides it with the ratio of the layout it
      // last committed. So the *value* of the default reaches no assertion
      // through the model, and it is a public constant the widget layer reads.
      //
      // 0.3pt is the input that separates the two candidates: nine tenths of a
      // physical pixel on a 3x display, which is a gap a phone can show, and
      // three fifths of one on a 1x display, which is not. Calibrating the
      // default for 1x stops every hand-built settle a visible step short.
      final settling = SettlingPanelActivity(
        destination: Detent.full,
        from: Extent(full.px - 0.3),
        to: full,
        velocity: ExtentVelocity.zero,
        motion: const PanelMotion.smooth(),
      );
      expect(
        settling.isDone,
        isFalse,
        reason: 'nine tenths of a physical pixel is still a gap on a 3x screen',
      );
      expect(settling.isTicking, isTrue);
      expect(settling.tolerance, kSettleTolerance);
      expect(kSettleTolerance, closeTo(0.5 / 3, 1e-12));
    });

    test('and stops asking for frames once it has', () {
      final model = newModel();
      model.beginActivity(settleTo(Detent.full, full));
      for (var frame = 0; frame < 200 && model.isTicking; frame++) {
        model.tick(const Duration(milliseconds: 16));
      }
      expect(model.isTicking, isFalse);
    });

    test('and never writes a negative extent, however far it undershoots', () {
      // A **floating** panel settling to a zero-height detent, under
      // `snappy`. Every part of that is the fixture rather than a scenario:
      //
      //  * floating, because an edge-attached panel keeps the 34pt home
      //    indicator under its smallest detent, so the spring undershoots into
      //    the padding and never reaches zero — measured, 29.13 at its lowest.
      //  * `snappy` and not the default `smooth`, because `smooth` has no
      //    bounce and never goes below zero at any release velocity tested. A
      //    test written with the default would pass against the unsaturated
      //    write.
      //  * zero release velocity, because that is the weakest input that still
      //    reproduces: this needs no fling.
      final floating = kIPhone17Pro.layout(attachment: EdgeAttachment.floating);
      const bottom = Detent.height(DetentValue.zero);
      final model = PanelModel(
        config: const PanelConfig(
          detents: DetentSet([bottom, Detent.full]),
          initialDetent: Detent.full,
          motion: PanelMotion.snappy(),
        ),
        layout: floating,
      );
      addTearDown(model.dispose);

      // The same spring the model is about to build, seeded identically, kept
      // unsaturated. Without this the assertions below would also be satisfied
      // by a spring that simply never went negative, which is the reading that
      // makes this test worthless.
      final from = model.extent;
      final unsaturated = const PanelMotion.snappy().createSimulation(
        start: from.px,
        end: 0,
        tolerance: const Tolerance(
          distance: kSettleTolerance,
          velocity: kSettleTolerance,
        ),
      );

      model.animateTo(bottom);
      const step = Duration(microseconds: 16667);
      var elapsed = Duration.zero;
      var frames = 0;
      var lowestWritten = double.infinity;
      var lowestSampled = double.infinity;
      while (model.isTicking && frames < 400) {
        model.tick(step);
        elapsed += step;
        final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
        lowestWritten = math.min(lowestWritten, model.extent.px);
        lowestSampled = math.min(lowestSampled, unsaturated.x(seconds));
        frames++;
      }

      expect(
        frames,
        greaterThan(20),
        reason: 'a settle that finished in three frames would prove nothing',
      );
      expect(
        lowestSampled,
        lessThan(0),
        reason:
            'the premise: this spring really does go below zero — about −1.26pt '
            'here. If it stops doing so the assertion below stops meaning '
            'anything, and this line is what says so',
      );
      expect(
        lowestWritten,
        0,
        reason:
            'and the extent bottoms out at exactly zero rather than at the '
            'sample. An Extent is "finite and non-negative by convention" — '
            'operator - saturates, PanelBaseline.frameOf saturates, '
            'Detent.resolve asserts — and this write was the one crossing that '
            'reached none of them. Below zero the panel is not short, it is '
            'absent, and absence is EdgeOffset\'s quantity',
      );
      expect(
        model.extent.px,
        0,
        reason: 'and it still arrives, because the floor is not a stop',
      );
      expect(model.activity, isA<IdlePanelActivity>());
    });
  });

  group('a fused ballistic', () {
    ScrollBallisticActivity fling({Duration window = kResnapWindow}) =>
        ScrollBallisticActivity(
          position: _FakeScroll(),
          velocity: const ExtentVelocity(1800),
          resnapWindow: window,
        );

    test('keeps its own clock', () {
      final ballistic = fling();
      expect(ballistic.elapsed, Duration.zero);
      ballistic.tick(const Duration(milliseconds: 16));
      ballistic.tick(const Duration(milliseconds: 16));
      expect(ballistic.elapsed, const Duration(milliseconds: 32));
    });

    test('and its window is measured on that clock, not on wall time', () {
      // Frame deltas rather than a total elapsed, so an activity installed
      // mid-flight starts at zero without the driver resetting anything.
      final ballistic = fling(window: const Duration(milliseconds: 50));
      expect(ballistic.isResnapping, isTrue);
      ballistic.tick(const Duration(milliseconds: 49));
      expect(ballistic.isResnapping, isTrue);
      ballistic.tick(const Duration(milliseconds: 2));
      expect(ballistic.isResnapping, isFalse);
    });

    test('and wants frames while it runs', () {
      final ballistic = fling();
      expect(ballistic.isTicking, isTrue);
      expect(ballistic.isUserDriven, isFalse);
    });

    test(
      'and slows down, so a re-projection re-projects from what is left',
      () {
        final ballistic = fling();
        final released = ballistic.velocity;
        ballistic.tick(const Duration(milliseconds: 100));
        expect(ballistic.velocity.pxPerSecond, lessThan(released.pxPerSecond));
        expect(
          ballistic.velocity.isGrowing,
          isTrue,
          reason:
              'a fling that has slowed is still a fling in the same '
              'direction',
        );
      },
    );

    test('and is not a terminal state: it hands the panel back when its '
        'throw and its window are both spent', () {
      // An activity that stays installed with nothing left to do is a panel
      // that can never re-resolve a detent again: every layout change after the
      // window closes reads `freeze` off it, so no rotation and no keyboard
      // ever moves it, and it sits at a height that need not be any of its
      // detents. `applyLayout`'s ResnapBallistic arm refuses to hand a *live*
      // fling to a self-driven settle because that drops the position which
      // makes it one gesture across two things; by here the throw is spent and
      // there is nothing left to be one gesture with.
      final model = newModel();
      final drag = ScrollDragActivity(position: _FakeScroll(), from: medium);
      model.beginActivity(drag);
      drag.end(const ExtentVelocity(1800));
      expect(model.activity, isA<ScrollBallisticActivity>());

      var frames = 0;
      while (model.isTicking && frames < 2000) {
        model.tick(const Duration(milliseconds: 16));
        frames++;
      }

      expect(
        model.activity,
        isNot(isA<ScrollBallisticActivity>()),
        reason: 'after $frames frames it is still installed',
      );
      expect(model.isTicking, isFalse);
      expect(model.activity, isA<IdlePanelActivity>());
    });

    test('and its window is what keeps it asking for frames when the throw '
        'is already spent', () {
      // The zero-length flight: a finger that stops before it lifts releases
      // under 1e-3 px/s, and a FrictionSimulation is done with that at t = 0.
      // Read off the simulation alone, `isTicking` is false from the first
      // frame — so the clock `isResnapping` is measured on never starts, the
      // window never closes, and "and then stops re-snapping" is unreachable
      // for the life of the panel.
      final model = newModel();
      final fling = ScrollBallisticActivity(
        position: _FakeScroll(),
        velocity: const ExtentVelocity(0.0005),
        resnapWindow: const Duration(milliseconds: 40),
      );
      model.beginActivity(fling);
      expect(fling.isResnapping, isTrue);
      expect(model.isTicking, isTrue, reason: 'the window is still open');

      model.tick(const Duration(milliseconds: 16));
      model.tick(const Duration(milliseconds: 16));
      expect(fling.isResnapping, isTrue);
      expect(fling.onLayoutChanged, isA<ResnapBallistic>());

      model.tick(const Duration(milliseconds: 16));
      expect(fling.elapsed, const Duration(milliseconds: 48));
      expect(fling.isResnapping, isFalse);
      expect(
        model.activity,
        isNot(same(fling)),
        reason: 'and the frame that closes the window is the one it ends in',
      );
    });

    test('and a release with nothing left to throw never becomes one at '
        'all', () {
      // Under a zero window there is no clock to run down either, so a fling
      // installed here would never be ticked and could never end. `cancel` is
      // what ends a gesture with no throw: nothing to fuse, the panel comes
      // back on its own, the list keeps the offset it was released at.
      final model = newModel(
        config: const PanelConfig(
          detents: _sheet,
          initialDetent: Detent.medium,
          resnapWindow: Duration.zero,
        ),
      );
      final scroll = _FakeScroll()..pixels = 300;
      final drag = ScrollDragActivity(position: scroll, from: medium);
      model.beginActivity(drag);
      drag.update(30);
      drag.end(ExtentVelocity.zero);

      expect(model.activity, isNot(isA<ScrollBallisticActivity>()));
      expect(model.activity, isA<SettlingPanelActivity>());
      expect(scroll.pixels, 300);
    });

    test('and keeps the position it was handed when something replaces it', () {
      // The disposal seam: the model disposes the outgoing activity, and what
      // it releases is the link — never the position, which the scroll layer
      // owns and hands across through `absorb`.
      final model = newModel();
      final scroll = _FakeScroll();
      model.beginActivity(
        ScrollBallisticActivity(
          position: scroll,
          velocity: const ExtentVelocity(1800),
          resnapWindow: kResnapWindow,
        ),
      );
      final ballistic = model.activity as ScrollBallisticActivity;

      model.goIdle(target: Detent.medium);
      expect(model.activity, isA<IdlePanelActivity>());
      expect(ballistic.position, same(scroll));
    });
  });
}
