import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/physics/snap.dart';

import '../fixtures/devices.dart';

/// The three-stop sheet every case below is asked of: a 180pt peek, iOS's
/// medium, and full. On an iPhone 17 Pro those are frames of 214, 469.68 and
/// 812 — each one the detent's value plus the 34pt the panel gives the home
/// indicator, which `PanelBaseline.frameOf` adds once for all three.
const _sheet = DetentSet([
  Detent.height(DetentValue(180)),
  Detent.medium,
  Detent.full,
]);

const _peek = Detent.height(DetentValue(180));

void main() {
  final detents = _sheet.resolve(kIPhone17Pro.panelBaseline());
  final peek = detents.extentOf(_peek)!;
  final medium = detents.extentOf(Detent.medium)!;
  final full = detents.extentOf(Detent.full)!;

  SnapDecision released(
    Extent from,
    double velocity, {
    SnapPolicy policy = SnapPolicy.projected,
  }) => snapTarget(
    from: from,
    velocity: ExtentVelocity(velocity),
    detents: detents,
    policy: policy,
  );

  group('a fling reaches as far as it was thrown', () {
    test('upward, past a detent in the middle', () {
      // S10. `stupid_simple_sheet`'s FlingSnapPhysics — its default — forbids
      // this by construction: it walks to the next point in the fling's
      // direction and stops there however hard the throw was.
      expect(released(peek, 3000).detent, Detent.full);
      expect(released(peek, 3000).extent, full);
    });

    test('downward, past the same one', () {
      // The mirror, asserted separately because "skipping works" is easy to make
      // true in one direction and false in the other.
      expect(released(full, -3000).detent, _peek);
      expect(released(full, -3000).extent, peek);
    });

    test('and a gentler throw reaches exactly one stop', () {
      expect(released(peek, 400).detent, Detent.medium);
      expect(released(full, -400).detent, Detent.medium);
    });

    test('and a nudge does not move it at all', () {
      // Which is why there is no fling-versus-drag velocity threshold anywhere
      // in this file: a slow release projects a few pixels, and the nearest
      // detent to a few pixels away is the one it started at. A threshold would
      // decide the same thing, with a constant to tune and a discontinuity at it.
      expect(released(peek, 100).detent, _peek);
      expect(released(medium, -80).detent, Detent.medium);
      expect(released(medium, 0).detent, Detent.medium);
    });

    test('the projection decides, so a release mid-travel lands sensibly', () {
      expect(released(const Extent(500), 0).detent, Detent.medium);
      expect(released(const Extent(700), 0).detent, Detent.full);
    });

    test('and every stop it can reach is a frame, not a detent value', () {
      // The fixtures below are read out of the resolved set rather than written
      // as numbers, so this is the one place the difference is pinned: a snap
      // decision is made in frame space throughout.
      final baseline = kIPhone17Pro.panelBaseline();
      expect(peek.px, 214.0);
      expect(medium.px, 0.56 * 778 + 34);
      expect(full.px, 812.0);
      expect(full.px, baseline.frameOf(Detent.full.resolve(baseline)!).px);
    });
  });

  group('the release velocity is never discarded', () {
    test('when the panel has to settle backwards against it', () {
      // Travelling up at 200 px/s from 480, the projection lands at 580 — and
      // the nearest detent to 580 is medium, at 469.68, which is *below* where
      // the finger let go. `smooth_sheets` substitutes zero here
      // (`lib/src/physics.dart:114-118`).
      final decision = released(const Extent(480), 200);
      expect(decision.detent, Detent.medium);
      expect(decision.extent.px, lessThan(480));
      expect(decision.velocity.pxPerSecond, 200.0);
      expect(decision.velocity.isGrowing, isTrue);
    });

    test('and in the other direction too', () {
      final decision = released(const Extent(430), -100);
      expect(decision.detent, Detent.medium);
      expect(decision.extent.px, greaterThan(430));
      expect(decision.velocity.pxPerSecond, -100.0);
    });

    test('at every release in the range, whatever was decided', () {
      for (var x = 0.0; x <= 900; x += 37) {
        for (final v in const [
          -4000.0,
          -900.0,
          -1.0,
          0.0,
          1.0,
          900.0,
          4000.0,
        ]) {
          for (final policy in SnapPolicy.values) {
            expect(
              released(Extent(x), v, policy: policy).velocity.pxPerSecond,
              v,
              reason: 'released at $x px, $v px/s, $policy',
            );
          }
        }
      }
    });
  });

  group('the policy is a window, and it is explicit', () {
    test('stepwise stops one detent from where the finger left', () {
      expect(
        released(peek, 3000, policy: SnapPolicy.stepwise).detent,
        Detent.medium,
      );
      expect(
        released(full, -3000, policy: SnapPolicy.stepwise).detent,
        Detent.medium,
      );
    });

    test('stepwise still reaches the next one when the throw warrants it', () {
      // "One stop per fling" is not "never move": from between two detents the
      // window is the bracketing pair, and a hard throw takes the far one. 500
      // sits between medium's 469.68 and full's 812.
      expect(
        released(const Extent(500), 3000, policy: SnapPolicy.stepwise).detent,
        Detent.full,
      );
    });

    test('the two policies disagree, so the enum is not decoration', () {
      expect(
        released(peek, 3000, policy: SnapPolicy.projected).detent,
        isNot(released(peek, 3000, policy: SnapPolicy.stepwise).detent),
      );
    });

    test('the default is the one that skips', () {
      expect(
        released(peek, 3000),
        released(peek, 3000, policy: SnapPolicy.projected),
      );
    });
  });

  group('releases from outside the travel', () {
    test('an over-drag above the top comes back to the top', () {
      for (final policy in SnapPolicy.values) {
        expect(
          released(const Extent(950), 500, policy: policy).detent,
          Detent.full,
        );
        expect(
          released(const Extent(950), -500, policy: policy).detent,
          Detent.full,
        );
      }
    });

    test('a drag below the bottom comes back to the bottom', () {
      for (final policy in SnapPolicy.values) {
        expect(released(const Extent(100), -500, policy: policy).detent, _peek);
        expect(released(const Extent(100), 0, policy: policy).detent, _peek);
      }
    });

    test('unless it is thrown back up, which is still a throw', () {
      // The asymmetry is deliberate and is the projection doing its job: 500
      // px/s upward from 114pt under the bottom detent projects past it, and
      // there is no reason a gesture that clearly meant "open" should be
      // truncated by where it happened to start. Only the stepwise window, which
      // collapses onto the bottom detent from below it, refuses.
      expect(released(const Extent(100), 500).detent, Detent.medium);
      expect(
        released(const Extent(100), 500, policy: SnapPolicy.stepwise).detent,
        _peek,
      );
    });

    test('and the raw projection is reported unclamped', () {
      // The caller that has to decide between rubber-banding and dismissing
      // needs to know how far past the end the gesture actually reached, so the
      // projection is carried even though the decision clamped it.
      final decision = released(full, -3000);
      expect(decision.landing, lessThan(0));
      expect(decision.extent, peek);
    });
  });

  group('degenerate sets', () {
    test('a one-detent panel goes nowhere, at any velocity', () {
      final single = const DetentSet([
        Detent.full,
      ]).resolve(kIPhone17Pro.panelBaseline());
      for (final v in const [-9000.0, 0.0, 9000.0]) {
        for (final policy in SnapPolicy.values) {
          final decision = snapTarget(
            from: single.max,
            velocity: ExtentVelocity(v),
            detents: single,
            policy: policy,
          );
          expect(decision.detent, Detent.full);
          expect(decision.extent, single.max);
          expect(decision.velocity.pxPerSecond, v);
        }
      }
    });
  });

  group('value semantics', () {
    test('two decisions from the same release are the same decision', () {
      final a = released(peek, 400);
      final b = released(peek, 400);
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, a);
      expect(a, isNot(released(peek, 3000)));
      expect(a, isNot(released(medium, 400)));
      expect(a, isNot(released(peek, 401)));
      expect(a, isNot(const Object()));
    });

    test('a decision says where it is going and what it is carrying', () {
      final decision = released(const Extent(480), 200);
      expect(decision.toString(), startsWith('SnapDecision(Detent.medium at '));
      expect(decision.toString(), contains('velocity: 200.0'));
      expect(decision.toString(), contains('landing: '));
    });
  });
}
