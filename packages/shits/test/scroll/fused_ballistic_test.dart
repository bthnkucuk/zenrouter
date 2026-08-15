import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/model/correction.dart';
import 'package:shits/src/physics/motion.dart';
import 'package:shits/src/physics/projection.dart';
import 'package:shits/src/physics/snap.dart';
import 'package:shits/src/physics/fused_axis.dart';
import 'package:shits/src/physics/fused_simulation.dart';

import '../fixtures/devices.dart';
import 'harness.dart';
import 'package:shits/src/physics/momentum.dart';

// ============================================================================
// One fling across two things.
//
// The claim is not "it looks smooth" — it is that a release which begins as a
// scroll and ends as a panel motion is **one simulation**, with a position that
// is continuous at the seam and a derivative that is continuous there too. A
// handoff between two simulations produces the same still frames and a
// different film: the second one starts from rest, or from a re-derived
// velocity, and the discontinuity is a sixteen-millisecond stall that reads as
// a dropped frame.
//
// So the assertions are one-sided limits and traces, not endpoints. An
// implementation that hands off correctly *by accident* — seeding the spring
// from the release velocity rather than from the seam velocity — passes every
// endpoint assertion and fails the limits.
//
// The seam here is 598: the panel's travel from the 214 peek to the 812 full.
// `projectLanding` is 0.49938 x velocity, so every release below is chosen so
// its landing is unambiguously on one side or the other.
// ============================================================================

/// How far either side of the crossing a one-sided limit is sampled, in
/// seconds.
///
/// **Amended from 1e-4, which no implementation can satisfy — including a
/// correct one.** The two continuity assertions below pair this window with a
/// tolerance of 1e-3, and at the crossing this file uses the fling is doing
/// 795.75px/s: over 1e-4s the position moves 0.0800px and the friction's own
/// velocity moves 0.159px/s, both already past 1e-3 before the spring is
/// reached. The spring seeded there is 342px from `.medium` and so starts at
/// −34,060px/s², which moves the velocity another 3.24px/s in the same window.
/// Measured, not derived: the three numbers are what the failures printed.
///
/// A one-sided limit is a statement about the neighbourhood of a point, so the
/// fix is the window and not the tolerance — widening the tolerance to 5px/s
/// would admit the claim while leaving it 40x looser than the error it is meant
/// to catch. At 1e-9 the friction moves 8e-7px and 1.6e-6px/s and the spring
/// 3.4e-5px/s, all inside 1e-3, while the two implementations these assertions
/// exist to kill still fail by the width of a whole release: seeding the spring
/// from the release velocity misses by 204px/s and zeroing it misses by 796.
const double kLimitWindow = 1e-9;

ResolvedDetents get _peek => kPeekSet.resolve(kIPhone17Pro.panelBaseline());

FusedAxis _axis({double scrollMax = 2000}) =>
    FusedAxis(detents: _peek, scrollMin: 0, scrollMax: scrollMax);

FusedSimulation _fling({
  required double from,
  required double velocity,
  double scrollMax = 2000,
  MomentumCarry carry = MomentumCarry.both,
  SnapPolicy snapPolicy = SnapPolicy.projected,
}) => FusedSimulation(
  axis: _axis(scrollMax: scrollMax),
  from: FusedPosition(from),
  velocity: velocity,
  motion: const PanelMotion.smooth(),
  snapPolicy: snapPolicy,
  carry: carry,
);

void main() {
  // The seam is 598 because the travel is 812 − 214. On `flutter_test`'s own
  // 800x600 surface the panel's baseline is measured from 600 instead of 874,
  // the travel becomes 324, and the widget group at the bottom is flinging
  // across a different axis from the one every number above was chosen against.
  useIPhone17Pro();

  group('which kind of fling this is', () {
    test('a landing in the content is a scroll, and snaps to nothing', () {
      // From 1000 — already in the list — with 2000px/s, the projection is
      // 1998.8, which is the list's business all the way. There is no detent
      // above the seam, so a destination here would be an invention.
      final fling = _fling(from: 1000, velocity: 2000);
      expect(projectLanding(1000, 2000), greaterThan(_axis().seam.px));
      expect(fling.destination, isNull);
      expect(fling.seamCrossing, isNull);
    });

    test('a landing in the panel snaps to the detent nearest it', () {
      // From 700, at -1000px/s, the projection is 200.6 — below the seam, and
      // nearer `.medium` at 255.68 than the peek at 0.
      final fling = _fling(from: 700, velocity: -1000);
      expect(fling.destination, Detent.medium);
    });

    test('a hard fling with nothing to scroll snaps instead of running on', () {
      // The case DESIGN.md §3.3's two-line rule does not cover. "Lands at or
      // above the seam -> the whole thing is friction" is right only when there
      // is content beyond the seam; with a short list the seam *is* the end of
      // the axis, and friction past it would carry the panel past `.full` under
      // deceleration rather than settling it there.
      //
      // The rule needs both halves: a fling is a scroll when its landing is at
      // or above the seam **and** the axis has content beyond it.
      final fling = _fling(from: 0, velocity: 3000, scrollMax: 0);
      expect(projectLanding(0, 3000), greaterThan(_axis().seam.px));
      expect(fling.destination, Detent.full);
    });

    test('S10: a hard fling crosses two stops and a flick crosses one', () {
      // The behaviour `stupid_simple_sheet`'s shipped `FlingSnapPhysics`
      // forbids — it documents itself as "snapping points can never be
      // overshot with a fling" and returns the next point in the direction of
      // travel whatever the velocity — so a three-detent sheet needs three
      // flings to open. No native scroll view does that with the same gesture.
      //
      // Both rows in one test, because the claim is the *difference*: an
      // implementation that always went to `.full` passes the first row alone.
      expect(
        _fling(from: 0, velocity: 3000, scrollMax: 0).destination,
        Detent.full,
      );
      expect(
        _fling(from: 0, velocity: 400, scrollMax: 0).destination,
        Detent.medium,
      );
    });

    test('stepwise confines the same release to one stop', () {
      // The panel's own snap policy, not a second one — so a fling that begins
      // on the handle and a fling that begins in the list choose the same
      // destination from the same projection.
      final fling = _fling(
        from: 0,
        velocity: 3000,
        scrollMax: 0,
        snapPolicy: SnapPolicy.stepwise,
      );
      expect(fling.destination, Detent.medium);
    });
  });

  group('the seam is C1, and that is the whole point', () {
    test('the position is continuous across the crossing', () {
      final fling = _fling(from: 700, velocity: -1000);
      final crossing = fling.seamCrossing!;
      final t = crossing.inMicroseconds / Duration.microsecondsPerSecond;
      expect(fling.x(t), closeTo(_axis().seam.px, 1e-6));
      expect(fling.x(t - kLimitWindow), closeTo(_axis().seam.px, 1e-3));
      expect(fling.x(t + kLimitWindow), closeTo(_axis().seam.px, 1e-3));
    });

    test('the velocity is continuous across the crossing', () {
      // The assertion that separates a fused simulation from a tidy handoff.
      // Seeding the spring with the *release* velocity instead of the velocity
      // read at the seam passes every endpoint assertion in this file and fails
      // here: by the time the fling reaches the seam, friction has taken a
      // third of the release off it.
      //
      // Zeroing it — which `smooth_sheets` does whenever the velocity points
      // away from the target (`lib/src/physics.dart:114-118`) — fails harder.
      final fling = _fling(from: 700, velocity: -1000);
      final t =
          fling.seamCrossing!.inMicroseconds / Duration.microsecondsPerSecond;
      final before = fling.dx(t - kLimitWindow);
      final after = fling.dx(t + kLimitWindow);
      expect(after, closeTo(before, 1e-3));
      expect(fling.seamVelocity, closeTo(before, 1e-3));
      // And it is genuinely slower than the release, so the assertion above is
      // not satisfied by "the velocity never changed".
      expect(before.abs(), lessThan(1000 * 0.9));
    });

    test('a release below the seam is all spring, with no crossing', () {
      // The same code with a zero-length friction phase. A drag of the panel's
      // own handle and a fling of a list at its top produce the same motion,
      // and the way that is true is that there is no second branch.
      final fling = _fling(from: 250, velocity: -300, scrollMax: 0);
      expect(fling.seamCrossing, isNull);
      expect(fling.dx(0), closeTo(-300, 1e-6));
      // No crossing, so there is no velocity read at one. Zero rather than the
      // release, because the number this getter names is what the *spring* was
      // seeded with at the seam, and this spring was not seeded there.
      expect(fling.seamVelocity, 0);
      // And the spring is running from t = 0 rather than from some later
      // instant: the peek sits at fused 0 and half a second is a whole
      // `PanelMotion.smooth`, so a spring that had not started yet would still
      // be at 250.
      expect(fling.x(1.0), closeTo(0, 0.5));
    });

    test('a velocity pointing away from the destination is carried, not zeroed', () {
      // Released at 254 — four pixels below `.medium` at 255.68 — drifting
      // downward at 5px/s. The projection is 251.5, still nearest `.medium`, so
      // the panel settles *up* while the finger was moving *down*.
      //
      // That is a real gesture and carrying it is what makes the curve read as
      // attached to the hand. `smooth_sheets` substitutes zero here, calling it
      // "intentionally set to 0 ... tends to cause unstable motion"; the
      // instability that describes is a spring tuned to tolerate being
      // restarted, and the fix is the tuning.
      final fling = _fling(from: 254, velocity: -5, scrollMax: 0);
      expect(fling.destination, Detent.medium);
      expect(fling.dx(0), -5);
    });

    test('done means both halves are done', () {
      // A friction that reported itself finished at the seam would stop the
      // ticker with the panel between detents — visibly short, and parked
      // there until something else touched it.
      final fling = _fling(from: 700, velocity: -1000);
      final t =
          fling.seamCrossing!.inMicroseconds / Duration.microsecondsPerSecond;
      expect(fling.isDone(t), isFalse);
      expect(fling.isDone(20), isTrue);
    });

    test('sampling is splitting, and there is only one crossing', () {
      // `sample` must be `axis.split(x(t))` and nothing else. Two paths from
      // the fused coordinate to the two things that move is how the extent and
      // the offset come to disagree about where the fling is — which is the
      // ten-line defensive comment in `smooth_sheets`' equivalent method.
      final fling = _fling(from: 700, velocity: -1000);
      for (final t in [0.0, 0.05, 0.2, 0.5, 1.0]) {
        final sampled = fling.sample(t);
        final split = _axis().split(FusedPosition(fling.x(t)));
        expect(sampled.extent.px, closeTo(split.extent.px, 1e-9));
        expect(sampled.scrollPixels, closeTo(split.scrollPixels, 1e-9));
      }
    });
  });

  group('momentum at the seam — [OPEN], so all three ship', () {
    test('both: the release crosses in either direction', () {
      expect(_fling(from: 700, velocity: -1000).seamCrossing, isNotNull);
      // And out of the panel into the list, which is the half that is actually
      // contested: a fling that expands the panel *and* keeps scrolling may
      // read as a loss of control, and that is what to try on a device.
      expect(_fling(from: 300, velocity: 2000).destination, isNull);
    });

    test('none: the seam is a wall in both directions', () {
      final down = _fling(
        from: 700,
        velocity: -1000,
        carry: MomentumCarry.none,
      );
      expect(down.seamCrossing, isNull);
      for (final t in [0.0, 0.1, 0.5, 2.0]) {
        expect(down.x(t), greaterThanOrEqualTo(_axis().seam.px - 1e-6));
      }
      // A wall confines the fling; it does not teleport it there. Both of these
      // are satisfied by a simulation pinned at the seam from t = 0, which is
      // what an over-eager clamp produces, and neither is satisfied by one that
      // ignores the wall.
      expect(down.x(0), closeTo(700, 1e-6));
      expect(down.dx(0), closeTo(-1000, 1e-6));
      // And what is left of the throw is spent there rather than reported as a
      // speed nobody can see — a `Scrollbar` reading it would show a list moving
      // while the wall holds it still.
      expect(down.dx(2), 0);
      expect(
        down.isDone(2),
        isTrue,
        reason:
            'the friction still has seconds of tail, and there is nowhere '
            'left for it to spend them',
      );

      final up = _fling(from: 300, velocity: 2000, carry: MomentumCarry.none);
      expect(up.destination, Detent.full);
      expect(up.x(0), closeTo(300, 1e-6));
      for (final t in [0.0, 0.1, 0.5, 2.0]) {
        expect(up.x(t), lessThanOrEqualTo(_axis().seam.px + 1e-6));
      }
    });

    test('none holds a release standing exactly on the wall', () {
      // The boundary the two readings of "which half did this start in"
      // disagree about, and the only input where they produce different
      // *motion* rather than different diagnostics. A release exactly on the
      // seam pointing into the panel is a crossing — there is nothing else it
      // could be — so under `none` the wall holds it and the panel does not
      // shrink at all.
      //
      // Read the other way (`from > seam`), the release counts as beginning in
      // the panel's half, the wall does not apply to it, and the momentum goes
      // straight through a policy whose whole content is that it may not. Every
      // other release in this group starts hundreds of pixels from the seam and
      // cannot tell the two apart.
      final seam = _axis().seam.px;
      final fling = _fling(
        from: seam,
        velocity: -1000,
        carry: MomentumCarry.none,
      );
      expect(
        fling.destination,
        isNull,
        reason: 'a detent to settle at is a fling that was allowed to cross',
      );
      expect(fling.seamCrossing, isNull, reason: 'a wall is not a crossing');
      for (final t in [0.0, 0.05, 0.2, 1.0]) {
        expect(fling.x(t), greaterThanOrEqualTo(seam - 1e-6));
      }
    });

    test('intoPanelOnly is the asymmetric one, and that is the point', () {
      // Into the panel it behaves like `both`; out of the panel it behaves like
      // `none`. Asserting only one direction would be satisfied by either of
      // the other two values, which is what makes a three-value policy worth
      // having only if the middle value is pinned on both sides.
      expect(
        _fling(
          from: 700,
          velocity: -1000,
          carry: MomentumCarry.intoPanelOnly,
        ).seamCrossing,
        isNotNull,
      );
      expect(
        _fling(
          from: 300,
          velocity: 2000,
          carry: MomentumCarry.intoPanelOnly,
        ).destination,
        Detent.full,
      );
    });
  });

  // ==========================================================================
  // And the same claims where they are actually observable: through a gesture,
  // on a real `Scrollable`, with a real ticker.
  // ==========================================================================
  group('a fling, as it actually runs', () {
    testWidgets('one ticker runs for the whole settle', (tester) async {
      // Falsification criterion 4, counted directly.
      // `SchedulerBinding.transientCallbackCount` is the number of running
      // tickers, and a fling that hands off from a scroll simulation to a panel
      // spring shows two of them for at least one frame — which is invisible
      // from the behaviour, because the two agree about position and disagree
      // only about who owns the next frame.
      //
      // The second assertion is what stops this passing trivially: an
      // implementation that runs no ticker at all also reports one at no point,
      // and a panel that never moved is not a fling.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      await tester.fling(find.byType(ListView), const Offset(0, -400), 2000);
      var maxTickers = 0;
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        maxTickers = maxTickers > tester.binding.transientCallbackCount
            ? maxTickers
            : tester.binding.transientCallbackCount;
      }
      await tester.pumpAndSettle();

      expect(maxTickers, 1);
      expect(link.model.extent.px, greaterThan(kPeekFrame));
    });

    testWidgets(
      'one activity: the panel is never handed to its own settle mid-fling',
      (tester) async {
        // The trace, rather than the endpoint. A handoff implementation reaches
        // the same detent and shows a `SettlingPanelActivity` on the way, because
        // that is what "the scroll finished, now the panel takes over" is.
        final link = linkAt(kPeekFrame);
        final seen = <Type>[];
        link.model.addListener(() {
          final type = link.model.activity.runtimeType;
          if (seen.isEmpty || seen.last != type) seen.add(type);
        });

        await tester.pumpWidget(
          panel(model: link.model, link: link, content: longList()),
        );
        await tester.fling(find.byType(ListView), const Offset(0, -400), 2000);
        await tester.pumpAndSettle();

        expect(
          seen.where((t) => t == SettlingPanelActivity),
          isEmpty,
          reason:
              'a settle in the trace is a second simulation with a name: $seen',
        );
        expect(seen, contains(ScrollBallisticActivity));
        expect(seen.last, IdlePanelActivity);
      },
    );

    testWidgets('the seam holds: the two never move in the same frame', (
      tester,
    ) async {
      // The invariant a fused axis produces and a pair of simulations does not.
      // Below the largest detent the panel is what moves and the list stays at
      // its start; the list only begins moving once the panel has arrived.
      //
      // Sampled every frame rather than at the end, because the violation is a
      // frame or two wide and both endpoints are correct in either design.
      //
      // **400pt of finger, not 600, and the number is the whole test.** The
      // travel is 598, so a 600pt drag parks the panel on its ceiling *before*
      // the finger lifts — and an invariant of the form "while the list moves
      // the panel is at its ceiling" has nothing left to violate when the panel
      // is already there at the moment of release. Every wrong release
      // satisfies it: reversing `PanelDrag.end`'s two calls un-fuses the fling
      // entirely (`content.end` reaches `goBallistic` before the model holds a
      // `ScrollBallisticActivity`, so the fused path is never taken and nothing
      // ticks the model), and at 600pt that is invisible. At 400 the release
      // leaves the panel at 607 with 205pt of headroom, and the un-fused
      // version scrolls the list from the first frame with the panel frozen
      // there.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      final list = tester.state<ScrollableState>(find.byType(Scrollable));
      await tester.fling(find.byType(ListView), const Offset(0, -400), 3000);
      // The two counters are what make the invariant non-vacuous, and they are
      // the two ways this fixture could go blind again: a release with no
      // headroom (the panel already at its ceiling on frame one) and a release
      // that never reaches the seam (the list never moves) both leave the
      // `if` below unentered, and an unentered `if` asserts nothing.
      var framesWithHeadroom = 0;
      var framesWithTheListMoving = 0;
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final position = list.position;
        final atCeiling = link.model.extent.isCloseTo(
          link.model.detents.max,
          devicePixelRatio: kIPhone17Pro.devicePixelRatio,
        );
        if (!atCeiling) framesWithHeadroom++;
        if (position.pixels > position.minScrollExtent) {
          framesWithTheListMoving++;
          expect(
            atCeiling,
            isTrue,
            reason:
                'the list moved at ${position.pixels} while the panel was at '
                '${link.model.extent.px}, so two things are being animated',
          );
        }
      }

      expect(
        framesWithHeadroom,
        greaterThan(0),
        reason:
            'the panel was on its ceiling for the whole fling, so the '
            'invariant above had nothing to violate — this is the blindness '
            'the 600pt fixture had',
      );
      expect(
        framesWithTheListMoving,
        greaterThan(0),
        reason:
            'the fling never crossed the seam, so the invariant above was '
            'never entered',
      );
      // And the panel is what the release actually carried across the seam:
      // it grew after the finger lifted rather than being left where the drag
      // put it. Without this a fling that dropped the panel's half entirely —
      // list scrolls, panel frozen at 607 until something else settles it —
      // would satisfy every assertion above by simply never entering the
      // seam-crossing branch until the panel had been parked by a later frame.
      expect(
        link.model.extent.px,
        kFullFrame,
        reason: 'the fling carried the panel the remaining 205pt of travel',
      );

      await tester.pumpAndSettle();
    });

    testWidgets('no spurious end-then-start in the notification trace', (
      tester,
    ) async {
      // One gesture, one scroll session. `Scrollbar`, `RefreshIndicator` and
      // every app listener key off this sequence, and a handoff that ends the
      // scroll to start the panel motion emits `ScrollEnd` immediately followed
      // by `ScrollStart` with no finger in between — which makes a scrollbar
      // fade out and back in mid-fling.
      final link = linkAt(kPeekFrame);
      final trace = NotificationTrace();

      await tester.pumpWidget(
        panel(model: link.model, link: link, content: trace.listen(longList())),
      );
      await tester.fling(find.byType(ListView), const Offset(0, -400), 2000);
      await tester.pumpAndSettle();

      expect(trace.hasSpuriousRestart, isFalse, reason: '${trace.types}');
      expect(trace.seen.whereType<ScrollStartNotification>(), hasLength(1));
      expect(trace.seen.whereType<ScrollEndNotification>(), hasLength(1));
    });

    testWidgets('a release from exactly the ceiling is still one fling', (
      tester,
    ) async {
      // The commonest release there is: drag until the panel is fully open, let
      // go, and the list carries on. The panel is then standing *exactly* on its
      // largest detent, which is the boundary `PanelScrollPosition`'s on-axis
      // test compares at — and a test written one pixel either side of it cannot
      // tell an inclusive bound from an exclusive one.
      //
      // Exclusive, that release stops being fused: the panel is handed to its
      // own settle and the list to the framework's ballistic, which is two
      // simulations and two tickers for one throw.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      await tester.fling(find.byType(ListView), const Offset(0, -600), 3000);
      await tester.pump(const Duration(milliseconds: 16));
      // Still the fling's panel, which is what "one fling" means on this side of
      // the seam: the model is holding the activity that answers `resnap`, not
      // one that has already parked. An exclusive bound hands the panel to its
      // own settle here, and the two halves of the release stop being one event
      // without either endpoint moving.
      expect(link.model.activity.onLayoutChanged, isA<ResnapBallistic>());

      var maxTickers = 0;
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        maxTickers = maxTickers > tester.binding.transientCallbackCount
            ? maxTickers
            : tester.binding.transientCallbackCount;
      }
      await tester.pumpAndSettle();

      expect(
        link.model.extent.px,
        kFullFrame,
        reason: 'the drag used up exactly the panel\'s travel',
      );
      expect(maxTickers, 1);
    });

    testWidgets('the panel re-snaps on the fling\'s own clock', (tester) async {
      // This activity is the only ticker, so it is also what advances the
      // model's clock — and it must advance it by the **frame delta**. Handing
      // it the total elapsed instead makes the clock grow quadratically: the
      // 150ms re-snap window closes on the fourth frame instead of the tenth,
      // and a page that settles 100ms into a fling stops re-projecting a landing
      // it has just invalidated.
      //
      // Five frames of 16ms is 80ms on the real clock and 400ms on the
      // quadratic one, which is what puts the two answers either side of the
      // window.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      await tester.fling(find.byType(ListView), const Offset(0, -400), 2000);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        link.model.activity.onLayoutChanged,
        isA<ResnapBallistic>(),
        reason: '80ms in, and the window is 150',
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(
        link.model.activity.onLayoutChanged,
        isA<FreezeExtent>(),
        reason:
            'and then it stops re-snapping, which is the other half of the '
            'policy and what stops a fling chasing every content change',
      );

      await tester.pumpAndSettle();
    });

    testWidgets('an off-axis release carries the throw the finger made', (
      tester,
    ) async {
      // The one path where the *panel's* own release velocity is read rather
      // than the fused axis': below its smallest detent the panel is off the
      // fused coordinate, so `goBallistic` hands it to `model.goBallistic` at
      // the speed the drag ended at rather than to a simulation. Seeded from
      // rest — or, worse, with the sign flipped — the sheet would turn round
      // under the finger at the instant it was let go.
      //
      // Measured: released at 77.1 with the throw still pointing down, the
      // panel keeps going to 60.5 before the band brings it back to the peek.
      // A release seeded backwards leaves 77.1 immediately, upward, and never
      // goes below it — which is why the assertion is the *deepest* point and
      // not the landing: both readings land on 214.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      await tester.fling(find.byType(ListView), const Offset(0, 300), 3000);
      final released = link.model.extent.px;
      expect(
        released,
        lessThan(kPeekFrame),
        reason:
            'the drag has to leave the panel below its smallest detent, '
            'or this is not the off-axis path at all',
      );

      var deepest = released;
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        deepest = deepest < link.model.extent.px
            ? deepest
            : link.model.extent.px;
      }
      await tester.pumpAndSettle();

      expect(
        deepest,
        lessThan(released - 5),
        reason:
            'the panel stopped dead at $released instead of spending what was '
            'left of the throw',
      );
      expect(link.model.extent.px, closeTo(kPeekFrame, 0.5));
    });

    testWidgets('a cancelled Drag hands the panel back at once', (
      tester,
    ) async {
      // `Drag.cancel` and not a `PointerCancelEvent`: an accepted drag that
      // loses its pointer goes through `DragGestureRecognizer._checkEnd`
      // (`monodrag.dart:753-765`) and arrives as `Drag.end`. `cancel` is what
      // `ScrollableState._handleDragCancel` calls when the recogniser is about
      // to be disposed under a live gesture, and it is asked for here directly
      // because the one route to it inside a panel is currently closed:
      // `setCanDrag(false)` is the only caller, it is fed
      // `physics.shouldAcceptUserOffset`, and `PanelScrollController` wraps
      // every position's physics in `AlwaysScrollableScrollPhysics`, which
      // answers true unconditionally. That is a fact about today's wiring, and
      // `Drag.cancel` is a contract this class implements either way.
      //
      // Both halves have to be told. The list's alone is not enough: its cancel
      // is `goBallistic(0)`, and with the list **overscrolled** that builds a
      // real spring-back simulation instead of falling through to `goIdle`, so
      // the model would keep a user-driven gesture with no finger behind it for
      // as long as the bounce lasts — answering `LayoutCorrection.freeze` to a
      // rotation or a keyboard the whole time. Fully open under the default
      // refresh policy is what puts the list into overscroll: the veto hands
      // the whole downward drag to a list with no room for it.
      final link = linkAt(kFullFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      final drag = list.position.drag(
        DragStartDetails(
          globalPosition: kInsidePanel,
          localPosition: kInsidePanel,
        ),
        () {},
      );
      drag.update(
        DragUpdateDetails(
          globalPosition: kInsidePanel + const Offset(0, 100),
          delta: const Offset(0, 100),
          primaryDelta: 100,
        ),
      );
      await tester.pump();

      expect(
        list.position.pixels,
        lessThan(0),
        reason:
            'the list has to be bouncing, or its own cancel reaches goIdle and '
            'releases the panel for a reason this test is not about',
      );
      expect(link.model.activity, isA<ScrollDragActivity>());

      drag.cancel();

      expect(
        link.model.activity,
        isNot(isA<ScrollDrivenActivity>()),
        reason:
            'the panel is still holding a finger that is no longer there: '
            '${link.model.activity}',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('the panel taken back mid-fling stops being written to', (
      tester,
    ) async {
      // The second half of "one ticker": this activity ends when the
      // simulation is done **or** when the model has replaced the activity it
      // installed. A programmatic move — `animateTo` from a button, a route
      // beginning its exit — is the ordinary way the second clause happens, and
      // without it the fling and the new spring both write the extent every
      // frame, from two clocks, one of which this activity is also advancing.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await tester.fling(find.byType(ListView), const Offset(0, -400), 3000);
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        list.position.toString(),
        contains('FusedBallisticActivity'),
        reason: 'the premise: the fling is still running',
      );

      link.model.animateTo(Detent.medium);
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        list.position.toString(),
        isNot(contains('FusedBallisticActivity')),
        reason: 'the fling is still writing an extent a spring now owns',
      );
      await tester.pumpAndSettle();
      expect(link.model.extent.px, closeTo(kMediumFrame, 0.5));
    });

    testWidgets('a fling that has finished ends itself', (tester) async {
      // The other end clause, and the one the model cannot supply. The model's
      // own `ScrollBallisticActivity` is a `FrictionSimulation` at the
      // *framework's* default tolerance of 1e-3 px/s, so it keeps ticking for
      // seconds after the motion has stopped — this fling's own tolerance is
      // half a physical pixel and its simulation is done in one. An activity
      // that only ended when something replaced it would hold the panel
      // scroll-driven, and the ticker running, for all of that: measured, 66
      // frames becomes 314.
      //
      // The release has to be a real throw, which is why it is 100pt at
      // 800px/s and not something smaller: `WidgetTester.fling` keeps twenty
      // velocity samples, and a 40pt drag leaves less than `kTouchSlop` of
      // travel inside that window — so `isFlingGesture` reports `Velocity.zero`
      // and the release is a lift, not a fling, which ends by a different route
      // entirely.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await tester.fling(find.byType(ListView), const Offset(0, -100), 800);
      var frames = 0;
      while (list.position.toString().contains('FusedBallisticActivity') &&
          frames < 400) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
      }

      expect(
        frames,
        greaterThan(1),
        reason: 'the fling never started, so this measures nothing',
      );
      expect(
        frames,
        lessThan(150),
        reason:
            'the simulation was done and the activity was still installed '
            '${frames * 16}ms in, with the panel already on its detent',
      );
      await tester.pumpAndSettle();
      expect(link.model.extent.px, closeTo(kFullFrame, 0.5));
    });

    testWidgets('the panel lands on a resolved detent', (tester) async {
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      await tester.fling(find.byType(ListView), const Offset(0, -200), 800);
      await tester.pumpAndSettle();

      final heights = [for (final (_, e) in link.model.detents.snaps) e.px];
      expect(
        heights.any(
          (h) =>
              (h - link.model.extent.px).abs() <
              0.5 / kIPhone17Pro.devicePixelRatio,
        ),
        isTrue,
        reason: 'landed at ${link.model.extent.px}, detents are $heights',
      );
      // Not the one it started at — otherwise "landed on a detent" is satisfied
      // by a fling that did nothing.
      expect(link.model.extent.px, isNot(closeTo(kPeekFrame, 1)));
    });
  });
}
