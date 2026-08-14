import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/units.dart';

void main() {
  group('Extent', () {
    test('zero is no span', () {
      expect(Extent.zero.px, 0.0);
    });

    test('adds', () {
      expect((const Extent(200) + const Extent(34)).px, 234.0);
    });

    test('subtracts, saturating at zero rather than going negative', () {
      expect((const Extent(778) - const Extent(435.68)).px, 778 - 435.68);
      // A single-detent set has max == min; its travel must be a distance of
      // zero, not a negative one the physics would integrate.
      expect((const Extent(180) - const Extent(778)).px, 0.0);
    });

    test('orders', () {
      expect(const Extent(180) < const Extent(778), isTrue);
      expect(const Extent(778) < const Extent(180), isFalse);
      expect(const Extent(778) > const Extent(180), isTrue);
      expect(const Extent(180) > const Extent(778), isFalse);
      expect(const Extent(180) < const Extent(180), isFalse);
      expect(const Extent(180) > const Extent(180), isFalse);
    });

    test('compares for sorting', () {
      expect(const Extent(180).compareTo(const Extent(778)), lessThan(0));
      expect(const Extent(778).compareTo(const Extent(180)), greaterThan(0));
      expect(const Extent(180).compareTo(const Extent(180)), 0);
    });

    test('clamps into a range', () {
      const lo = Extent(180);
      const hi = Extent(778);
      expect(const Extent(0).clampTo(lo, hi).px, 180.0);
      expect(const Extent(1000).clampTo(lo, hi).px, 778.0);
      expect(const Extent(435.68).clampTo(lo, hi).px, 435.68);
    });

    test('is close within half a physical pixel, and not beyond it', () {
      // The gap between 0.56 x 778 and the 3x-rounded value the platform
      // reports. Same detent; different rounding.
      expect(
        const Extent(
          435.68,
        ).isCloseTo(const Extent(435.667), devicePixelRatio: 3),
        isTrue,
      );
      expect(
        const Extent(
          435.68,
        ).isCloseTo(const Extent(435.5), devicePixelRatio: 3),
        isFalse,
      );
      // A denser screen is stricter about the same pair.
      expect(
        const Extent(100).isCloseTo(const Extent(100.2), devicePixelRatio: 1),
        isTrue,
      );
      expect(
        const Extent(100).isCloseTo(const Extent(100.2), devicePixelRatio: 3),
        isFalse,
      );
    });
  });

  group('DetentValue', () {
    test('zero is a panel showing none of itself', () {
      expect(DetentValue.zero.px, 0.0);
    });

    test('clamps into a range, for a ratio that overshoots its baseline', () {
      const lo = DetentValue(0);
      const hi = DetentValue(778);
      expect(const DetentValue(-10).clampTo(lo, hi).px, 0.0);
      expect(const DetentValue(1200).clampTo(lo, hi).px, 778.0);
      expect(const DetentValue(435.68).clampTo(lo, hi).px, 435.68);
    });

    test('is not an Extent, and the frame is what tells them apart', () {
      // The separation A1 exists for: the value is what iOS reports, the frame
      // is what gets laid out, and they differ by the attachment padding. This
      // is the arithmetic; `baseline_test.dart` asserts it against the device.
      const value = DetentValue(778);
      const frame = Extent(812);
      expect(frame.px - value.px, 34.0);
    });
  });

  group('Baseline', () {
    test('becomes the value of a panel that fills the safe area', () {
      expect(const Baseline(778).asDetentValue.px, 778.0);
    });
  });

  group('ViewportExtent', () {
    test('carries the raw span, which is not the baseline', () {
      const viewport = ViewportExtent(874);
      const baseline = Baseline(778);
      expect(viewport.px - baseline.px, 96.0);
    });
  });

  group('Fraction', () {
    test('answers a detent value, which the frame is taller than', () {
      // Typed, not merely documented: if `of` went back to answering an Extent
      // this stops compiling, and every ratio detent would be one attachment
      // padding shorter than the absolute detent beside it again.
      final DetentValue value = const Fraction(0.56).of(const Baseline(778));
      expect(value.px, 0.56 * 778);
    });

    test('resolves against a baseline', () {
      expect(const Fraction(0.56).of(const Baseline(778)).px, 0.56 * 778);
      expect(const Fraction(0.5).of(const Baseline(778)).px, 389.0);
      expect(const Fraction(0).of(const Baseline(778)).px, 0.0);
    });

    test('mirrors a negative fraction rather than clamping it', () {
      expect(
        const Fraction(-0.2).of(const Baseline(778)).px,
        const Fraction(0.2).of(const Baseline(778)).px,
      );
      expect(const Fraction(-0.2).of(const Baseline(778)).px, greaterThan(0));
    });
  });

  group('EdgeOffset', () {
    test('zero is at rest', () {
      expect(EdgeOffset.zero.px, 0.0);
    });

    test('adds', () {
      expect((const EdgeOffset(10) + const EdgeOffset(5)).px, 15.0);
    });

    test('is fully present at rest, whichever detent that is', () {
      // The point of deriving presence from displacement rather than from size:
      // a sheet resting at a half-height detent is not half dismissed.
      expect(
        EdgeOffset.zero.presentationProgress(
          const Extent(778),
          restingOffset: EdgeOffset.zero,
        ),
        1.0,
      );
      expect(
        EdgeOffset.zero.presentationProgress(
          const Extent(435.68),
          restingOffset: EdgeOffset.zero,
        ),
        1.0,
      );
    });

    test('is fully present at rest for a placement that rests off zero', () {
      // A2. A 300pt dialog centred in an 874pt viewport rests at (874-300)/2 =
      // 287, and it is on screen and opaque there. Measured from zero it
      // reported 1 - 287/300 = 0.043: a barrier 4% opaque behind a finished
      // dialog, and a route simulation seeded from 4% — which is the defect
      // DESIGN.md rejects design B for, arrived at from the other end.
      const resting = EdgeOffset(287);
      expect(
        resting.presentationProgress(const Extent(300), restingOffset: resting),
        1.0,
      );
      expect(
        resting.presentationProgress(const Extent(300), restingOffset: resting),
        isNot(closeTo(0.043, 1e-3)),
      );
    });

    test('falls to zero as the panel leaves, from wherever it rests', () {
      expect(
        const EdgeOffset(389).presentationProgress(
          const Extent(778),
          restingOffset: EdgeOffset.zero,
        ),
        0.5,
      );
      expect(
        const EdgeOffset(778).presentationProgress(
          const Extent(778),
          restingOffset: EdgeOffset.zero,
        ),
        0.0,
      );
      // The same half-way point for the dialog, offset by where it rests: 287
      // at rest, 587 fully gone, 437 half gone.
      expect(
        const EdgeOffset(437).presentationProgress(
          const Extent(300),
          restingOffset: const EdgeOffset(287),
        ),
        closeTo(0.5, 1e-12),
      );
      expect(
        const EdgeOffset(587).presentationProgress(
          const Extent(300),
          restingOffset: const EdgeOffset(287),
        ),
        0.0,
      );
    });

    test('clamps outside the travel, and answers zero for an empty panel', () {
      expect(
        const EdgeOffset(1000).presentationProgress(
          const Extent(778),
          restingOffset: EdgeOffset.zero,
        ),
        0.0,
      );
      expect(
        const EdgeOffset(-10).presentationProgress(
          const Extent(778),
          restingOffset: EdgeOffset.zero,
        ),
        1.0,
      );
      expect(
        const EdgeOffset(
          10,
        ).presentationProgress(Extent.zero, restingOffset: EdgeOffset.zero),
        0.0,
      );
      // Behind its resting place is still fully present, not more than present.
      expect(
        const EdgeOffset(200).presentationProgress(
          const Extent(300),
          restingOffset: const EdgeOffset(287),
        ),
        1.0,
      );
    });
  });

  group('ExtentVelocity', () {
    test('zero is still', () {
      expect(ExtentVelocity.zero.pxPerSecond, 0.0);
    });

    test('negates', () {
      expect((-const ExtentVelocity(1200)).pxPerSecond, -1200.0);
    });

    test('grows only when positive', () {
      expect(const ExtentVelocity(1200).isGrowing, isTrue);
      expect(const ExtentVelocity(0).isGrowing, isFalse);
      expect(const ExtentVelocity(-1200).isGrowing, isFalse);
    });
  });

  group('ScrollVelocity', () {
    test('carries px/s in scroll space', () {
      expect(const ScrollVelocity(-1200).pxPerSecond, -1200.0);
    });
  });

  group('FusedPosition', () {
    test('carries a position on the fused axis', () {
      expect(const FusedPosition(1200).px, 1200.0);
    });
  });

  group('the erasure limit', () {
    test('is real, and is the whole of what these types do not promise', () {
      // Documented in the library doc: they prevent arithmetic and argument
      // confusion, not equality against the representation. If this ever starts
      // failing, someone has added `implements double` and the guarantees
      // changed shape.
      // ignore: unrelated_type_equality_checks
      expect(const Extent(0.56) == 0.56, isTrue);
      expect(identical(const Extent(778).px, 778.0), isTrue);
      expect(const Extent(778).toString(), '778.0');
    });
  });
}
