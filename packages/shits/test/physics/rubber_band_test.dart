import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/physics/rubber_band.dart';

import '../fixtures/devices.dart';

/// `BouncingScrollPhysics.frictionFactor`, copied out of
/// `flutter/lib/src/widgets/scroll_physics.dart` so that the comparisons below
/// are against the real curve rather than against a description of it.
double _flutterFrictionFactor(double overscrollFraction) =>
    0.52 * (math.pow(1 - overscrollFraction, 2) as double);

void main() {
  final viewport = kIPhone17Pro.panelBaseline().viewportSpan;
  final band = RubberBand(viewport: viewport);

  group('one formula', () {
    test('slope is the analytic derivative of map, to 1e-6, over [0, 3L]', () {
      // The test the whole class exists for. `stupid_simple_sheet` ships
      // `1/(1 + overshoot·R)` for the drag and `1/(maxExtent + overshoot·R)` for
      // the release, under a comment claiming they are the same factor
      // (`lib/stupid_simple_sheet.dart:557` and `:600`). Two formulas can drift;
      // a function and its derivative cannot, and this is what says so.
      //
      // A central difference at this step is accurate to about 1e-11 on this
      // curve, so a failure here is a real disagreement and not the numerics.
      const h = 0.01;
      final limit = 3 * viewport.px;
      for (var x = h; x <= limit; x += 7.3) {
        final numeric = (band.map(x + h).px - band.map(x - h).px) / (2 * h);
        expect(
          numeric,
          moreOrLessEquals(band.slope(x), epsilon: 1e-6),
          reason: 'at $x px of overshoot',
        );
      }
      // The one point a central difference cannot straddle, because the band
      // takes a magnitude. Pinned to the closed form instead.
      expect(band.slope(0), 0.55);
    });

    test('inverse round-trips map over the same range', () {
      // The third function has to be the same function too: a drag that comes
      // back has to restore the raw position the finger is actually at, or the
      // next delta resumes from a resisted one and the resistance compounds.
      for (var x = 0.0; x <= 3 * viewport.px; x += 13.7) {
        expect(
          band.inverse(band.map(x)),
          moreOrLessEquals(x, epsilon: 1e-9),
          reason: 'at $x px of overshoot',
        );
      }
    });

    test('the accumulated position is the only state', () {
      // What is *not* asserted here, and why: DESIGN.md §2.6 asks for path
      // independence — "100px in one delta equals 100px in a hundred deltas" —
      // and it is not a property of this class. `map` is a pure function of one
      // number. Summing a hundred 1.0s gives exactly 100.0 in binary floating
      // point, so the version of this that built `raw` in a loop and compared
      // `map(raw)` to `map(100)` was `map(100.0) == map(100.0)`: the same call
      // twice, which passes for every implementation including a wrong one.
      //
      // Path independence belongs to whoever *accumulates* the raw position —
      // the drag activity, which this slice does not ship — and it is a property
      // of that accumulation, not of the curve. It is asserted there, in
      // `test/model/`, when the activity lands.
      //
      // What this layer can say is the half that is about the curve: resisting
      // each delta on its own and summing the results — which is what
      // integrating frame-sized fragments amounts to, and what `smooth_sheets`
      // does at `lib/src/physics.dart:213-236` — is a *different curve* with no
      // asymptote at all. Two thousand one-pixel deltas move the panel further
      // than the viewport it is in, where the real band has not reached half of
      // it. That is the mistake the accumulate-then-map shape prevents, and it
      // fails loudly if `map` is ever made linear.
      var perDelta = 0.0;
      for (var i = 0; i < 2000; i++) {
        perDelta += band.map(1).px;
      }
      expect(perDelta, greaterThan(band.asymptote.px));
      expect(band.map(2000).px, lessThan(band.asymptote.px));
      expect(perDelta, greaterThan(2 * band.map(2000).px));
    });
  });

  group('normalised to the viewport', () {
    // A tall phone, a short one, and the *width* of the first — a drawer's span
    // axis. Nothing about the feel may depend on which of these it is.
    final tall = RubberBand(viewport: const ViewportExtent(956));
    final short = RubberBand(viewport: const ViewportExtent(844));
    final drawer = RubberBand(viewport: const ViewportExtent(402));

    test('equal normalised overshoot gives equal normalised resistance', () {
      for (final fraction in const [0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0]) {
        final t = tall.slope(fraction * 956);
        expect(
          short.slope(fraction * 844),
          moreOrLessEquals(t, epsilon: 1e-12),
        );
        expect(
          drawer.slope(fraction * 402),
          moreOrLessEquals(t, epsilon: 1e-12),
        );
      }
    });

    test('equal normalised overshoot gives equal normalised displacement', () {
      for (final fraction in const [0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0]) {
        final t = tall.map(fraction * 956).px / 956;
        expect(
          short.map(fraction * 844).px / 844,
          moreOrLessEquals(t, epsilon: 1e-12),
        );
        expect(
          drawer.map(fraction * 402).px / 402,
          moreOrLessEquals(t, epsilon: 1e-12),
        );
      }
    });

    test('and the normalisation is doing work, not nothing', () {
      // The same test would pass on an un-normalised band if these agreed too.
      // At equal *absolute* overshoot the three must differ, or `viewport` is
      // being ignored.
      expect(tall.map(200).px, isNot(closeTo(drawer.map(200).px, 1.0)));
      expect(tall.slope(200), isNot(closeTo(drawer.slope(200), 1e-3)));
    });

    test('the asymptote is one viewport, and the curve stays below it', () {
      expect(band.asymptote.px, viewport.px);
      expect(band.map(1e6).px, lessThan(viewport.px));
      expect(band.map(1e6).px, greaterThan(0.99 * viewport.px));
      // Every overshoot a gesture could produce, and then fifteen orders of
      // magnitude more.
      for (final x in const [1e3, 1e6, 1e9, 1e12, 1e15, 1e18]) {
        expect(band.map(x).px, lessThan(viewport.px), reason: 'at $x');
      }
    });

    test('and past the saturation bound it reaches it, which is documented', () {
      // The claim used to be "never reached", and it is false at the top of the
      // range: `c·x/L` passes 2^53 at about 1.43e19 px on this viewport, the
      // `1 +` in u stops changing it, and the ratio collapses to exactly one.
      // Pinned on both sides so the bound in the doc cannot rot, and because
      // this is the one displacement `inverse` cannot take.
      expect(band.map(1e19).px, lessThan(viewport.px));
      expect(band.map(1e20).px, viewport.px);
      expect(() => band.inverse(band.map(1e20)), throwsAssertionError);
      // Below the bound the two still agree, which is the property that
      // matters: nothing map produces from a real overshoot is uninvertible.
      // Only the order of magnitude is asserted at 1e18 — `limit - applied` is
      // 1.5e-12 there and has four significant digits left, so the round trip
      // is 6% out for reasons that are the subtraction's and not the band's.
      // Its accuracy is asserted over the range that matters, [0, 3L], above.
      expect(band.inverse(band.map(1e18)), closeTo(1e18, 1e17));
    });
  });

  group('chpwn, not BouncingScrollPhysics', () {
    // 800 is the one viewport at which the two published numbers are directly
    // comparable: Flutter's factor is exactly 0.130 at 400pt there, because
    // 400/800 is exactly a half.
    final at800 = RubberBand(viewport: const ViewportExtent(800));

    test('0.55 at the origin, where Flutter is 0.52', () {
      expect(at800.slope(0), 0.55);
      expect(_flutterFrictionFactor(0), 0.52);
    });

    test('0.431 of the drag still shows at 400pt', () {
      expect(at800.map(400).px / 400, moreOrLessEquals(0.431, epsilon: 5e-4));
      expect(
        _flutterFrictionFactor(400 / 800),
        moreOrLessEquals(0.130, epsilon: 1e-9),
      );
      // Marginal resistance at the same point: a third of the finger's motion
      // still comes through, against Flutter's eighth. The curves are not
      // approximations of each other.
      expect(at800.slope(400), moreOrLessEquals(0.338, epsilon: 5e-4));
      expect(
        at800.slope(400),
        greaterThan(2 * _flutterFrictionFactor(400 / 800)),
      );
    });

    test(
      'at one whole viewport of overdrag ours still moves and Flutter stops',
      () {
        expect(_flutterFrictionFactor(1.0), 0.0);
        expect(at800.slope(800), greaterThan(0.22));
      },
    );
  });

  group('velocity is scaled, never discarded', () {
    test('the drag-end scale is strictly positive at every overshoot', () {
      for (var x = 0.0; x <= 50 * viewport.px; x += viewport.px / 3) {
        expect(band.slope(x), greaterThan(0), reason: 'at $x px of overshoot');
      }
      // Even absurdly far out. A release is still a release.
      expect(band.slope(1e9), greaterThan(0));
    });

    test('and it says where that stops, because it does stop', () {
      // The claim used to be "strictly positive for every finite input". It is
      // not: `u²` overflows to infinity above u ≈ sqrt(maxFinite), which is
      // about 2.13e157 px of overshoot on this viewport, and c/infinity is 0.
      // The bound is asserted from both sides so that the doc comment and the
      // arithmetic cannot drift apart.
      for (final x in const [1e20, 1e50, 1e100, 1e150, 2e157]) {
        expect(band.slope(x), greaterThan(0), reason: 'at $x px of overshoot');
      }
      expect(band.slope(1e160), 0.0);
      expect(band.slope(double.maxFinite), 0.0);
    });

    test('and never exceeds the resistance at the origin', () {
      for (var x = 0.0; x <= 3 * viewport.px; x += 37.0) {
        expect(band.slope(x), lessThanOrEqualTo(band.c));
      }
    });
  });

  group('refusals', () {
    test('a zero viewport is refused at construction', () {
      expect(
        () => RubberBand(viewport: const ViewportExtent(0)),
        throwsAssertionError,
      );
      expect(
        () => RubberBand(viewport: const ViewportExtent(-1)),
        throwsAssertionError,
      );
    });

    test('resistance outside (0, 1] is refused', () {
      expect(() => RubberBand(viewport: viewport, c: 0), throwsAssertionError);
      expect(
        () => RubberBand(viewport: viewport, c: 1.5),
        throwsAssertionError,
      );
      expect(RubberBand(viewport: viewport, c: 1).slope(0), 1.0);
    });

    test('the band takes a magnitude', () {
      expect(() => band.map(-1), throwsAssertionError);
      expect(() => band.slope(-1), throwsAssertionError);
      expect(() => band.map(double.infinity), throwsAssertionError);
      expect(() => band.slope(double.nan), throwsAssertionError);
    });

    test('nothing at or past the asymptote can be inverted', () {
      expect(() => band.inverse(band.asymptote), throwsAssertionError);
      expect(() => band.inverse(const Extent(-1)), throwsAssertionError);
    });
  });

  group('value semantics', () {
    test('two bands on the same viewport are the same band', () {
      final a = RubberBand(viewport: const ViewportExtent(874));
      final b = RubberBand(viewport: const ViewportExtent(874));
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, a);
      expect(a, isNot(RubberBand(viewport: const ViewportExtent(844))));
      expect(a, isNot(RubberBand(viewport: const ViewportExtent(874), c: 0.4)));
      expect(a, isNot(const Object()));
    });

    test('a band says what it is', () {
      expect(
        RubberBand(viewport: const ViewportExtent(874)).toString(),
        'RubberBand(viewport: 874.0, c: 0.55)',
      );
    });
  });
}
