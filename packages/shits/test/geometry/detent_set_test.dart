import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/baseline.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';

import '../fixtures/devices.dart';

/// A set built the way a `build` method builds one: at runtime, with nothing
/// canonicalised, so equality is doing real work rather than comparing a const
/// to itself.
DetentSet _rebuilt() {
  final detents = <Detent>[Detent.full, Detent.medium];
  return DetentSet(detents);
}

/// The same, for the detent kind that carries a payload.
DetentSet _fractionSet(double value) {
  final detents = <Detent>[Detent.fraction(Fraction(value))];
  return DetentSet(detents);
}

/// A drawer's baseline — the third shape `Detent.full` has to be active on.
PanelBaseline _horizontal() => PanelBaseline.from(
  viewport: const Size(874, 402),
  viewPadding: const EdgeInsets.only(left: 62, right: 62),
  anchor: PanelAnchor.leading,
  textDirection: TextDirection.ltr,
);

void main() {
  final baseline = kIPhone17Pro.panelBaseline();
  // The frames those three resolve to on an iPhone 17 Pro, each one an attachment
  // padding above the value the detent itself answers.
  const peekFrame = 214.0; // value 180 + 34
  final mediumFrame = 0.56 * 778 + 34; // value 435.68 + 34
  const fullFrame = 812.0; // value 778 + 34
  // Deliberately written largest-first. The package this one is measured against
  // sorts its snaps, then indexes the unsorted list, then steps a neighbour in
  // the sorted one — so every question below is asked of a descending set.
  const descending = DetentSet([
    Detent.full, // frame 812
    Detent.medium, // frame 469.68
    Detent.height(DetentValue(180)), // frame 214, edge-attached
  ]);

  group('resolution', () {
    test('sorts ascending whatever order it was written in', () {
      final resolved = descending.resolve(baseline);
      expect(resolved.snaps.map((s) => s.$2.px), [
        peekFrame,
        mediumFrame,
        fullFrame,
      ]);
      expect(resolved.snaps.map((s) => s.$1), [
        Detent.height(const DetentValue(180)),
        Detent.medium,
        Detent.full,
      ]);
    });

    test('answers frames, so a value never escapes the set', () {
      // A1: the detent resolves a content span and `frameOf` converts it, once,
      // here. Every consumer downstream — rectOf, the snap decision, the model —
      // takes a frame, so the padding is added in exactly one place.
      final resolved = descending.resolve(baseline);
      for (final (detent, frame) in resolved.snaps) {
        expect(
          frame.px,
          baseline.frameOf(detent.resolve(baseline)!).px,
          reason: '$detent',
        );
        expect(
          frame.px - detent.resolve(baseline)!.px,
          34.0,
          reason: '$detent',
        );
      }
    });

    test('drops an inactive detent without disturbing the rest', () {
      final compact = PanelBaseline.from(
        viewport: Size(kIPhone17Pro.size.height, kIPhone17Pro.size.width),
        viewPadding: const EdgeInsets.only(bottom: 34),
        anchor: PanelAnchor.bottom,
        textDirection: TextDirection.ltr,
      );
      final resolved = descending.resolve(compact);
      expect(resolved.snaps.length, 2);
      expect(resolved.extentOf(Detent.medium), isNull);
      expect(
        resolved.extentOf(Detent.height(const DetentValue(180)))!.px,
        214.0,
      );
      expect(
        resolved.extentOf(Detent.full)!.px,
        compact.safeSpan.px + compact.attachedPadding.px,
      );
    });

    group('a set with nothing active falls back to a full panel', () {
      // A4. iOS accepts `sheet.detents = [.medium]` and shows a full sheet in
      // compact height, so this is a supported configuration reached by
      // rotating the device — not a programmer error. It used to assert, which
      // hard-failed a legal app from inside a layout pass on every frame after
      // the rotation, and left the release path unreachable by any test.
      final landscape = PanelBaseline.from(
        viewport: const Size(874, 402),
        viewPadding: const EdgeInsets.only(bottom: 21),
        anchor: PanelAnchor.bottom,
        textDirection: TextDirection.ltr,
      );

      test('a medium-only set in compact height, which iOS accepts', () {
        final resolved = const DetentSet([Detent.medium]).resolve(landscape);
        expect(resolved.snaps.length, 1);
        expect(resolved.snaps.single.$1, Detent.full);
        // The full frame on that baseline, through the same conversion every
        // other detent takes: safe span 402 - 21 = 381, plus the 21pt padding.
        expect(resolved.snaps.single.$2.px, 402.0);
        expect(
          resolved.snaps.single.$2.px,
          landscape.frameOf(Detent.full.resolve(landscape)!).px,
        );
        expect(resolved.min, resolved.max);
        expect(resolved.travel.px, 0.0);
      });

      test('and an empty set, by the same rule rather than a second one', () {
        final resolved = const DetentSet([]).resolve(baseline);
        expect(resolved.snaps.single.$1, Detent.full);
        expect(resolved.snaps.single.$2.px, fullFrame);
      });

      test('the fallback detent is the one that is never inactive', () {
        // What makes the `!` in the fallback total: Detent.full is the safe
        // span, which every baseline has, on every axis and in compact height.
        for (final b in [landscape, baseline, _horizontal()]) {
          expect(Detent.full.resolve(b), isNotNull, reason: '$b');
        }
      });
    });

    test('the resolved list cannot be edited from outside', () {
      final resolved = descending.resolve(baseline);
      expect(
        () => resolved.snaps.add((Detent.full, const Extent(1))),
        throwsUnsupportedError,
      );
    });

    test('nothing is dismissible yet', () {
      expect(descending.resolve(baseline).dismissible, isFalse);
    });
  });

  group('queries', () {
    late ResolvedDetents resolved;

    setUp(() => resolved = descending.resolve(baseline));

    test('min, max and travel', () {
      expect(resolved.min.px, peekFrame);
      expect(resolved.max.px, fullFrame);
      expect(resolved.travel.px, fullFrame - peekFrame);
    });

    test('travel is zero for a single-detent panel', () {
      final single = const DetentSet([Detent.full]).resolve(baseline);
      expect(single.travel.px, 0.0);
      expect(single.min.px, single.max.px);
    });

    test('extentOf answers only for detents that are in the set', () {
      expect(resolved.extentOf(Detent.full)!.px, fullFrame);
      expect(resolved.extentOf(Detent.fraction(const Fraction(0.25))), isNull);
    });

    test('nearestTo picks the closest stop', () {
      expect(
        resolved.nearestTo(const Extent(0)),
        Detent.height(const DetentValue(180)),
      );
      expect(
        resolved.nearestTo(const Extent(300)),
        Detent.height(const DetentValue(180)),
      );
      expect(resolved.nearestTo(const Extent(430)), Detent.medium);
      expect(resolved.nearestTo(const Extent(700)), Detent.full);
      expect(resolved.nearestTo(const Extent(2000)), Detent.full);
      expect(resolved.nearestTo(const Extent(812)), Detent.full);
    });

    test('a tie goes to the shorter detent, deterministically', () {
      // Round numbers on a floating placement, so the two distances are exactly
      // equal in binary and the tie is a real tie rather than a rounding.
      final even =
          const DetentSet([
            Detent.height(DetentValue(100)),
            Detent.height(DetentValue(300)),
          ]).resolve(
            kIPhone17Pro.panelBaseline(attachment: EdgeAttachment.floating),
          );
      expect(
        even.nearestTo(const Extent(200)),
        Detent.height(const DetentValue(100)),
      );
    });

    test('neighbourAbove steps up, and stops at the top', () {
      expect(resolved.neighbourAbove(const Extent(0))!.px, peekFrame);
      expect(resolved.neighbourAbove(const Extent(214))!.px, mediumFrame);
      expect(resolved.neighbourAbove(const Extent(500))!.px, fullFrame);
      expect(resolved.neighbourAbove(const Extent(812)), isNull);
      expect(resolved.neighbourAbove(const Extent(1000)), isNull);
    });

    test('neighbourBelow steps down, and stops at the bottom', () {
      expect(resolved.neighbourBelow(const Extent(1000))!.px, fullFrame);
      expect(resolved.neighbourBelow(const Extent(812))!.px, mediumFrame);
      expect(resolved.neighbourBelow(const Extent(500))!.px, mediumFrame);
      expect(resolved.neighbourBelow(const Extent(214)), isNull);
      expect(resolved.neighbourBelow(const Extent(0)), isNull);
    });

    test('the neighbours are strict, so a panel at rest reports no room', () {
      final single = const DetentSet([Detent.full]).resolve(baseline);
      expect(single.neighbourAbove(single.max), isNull);
      expect(single.neighbourBelow(single.min), isNull);
    });

    test('select opens where it was asked to', () {
      expect(resolved.select(Detent.medium).px, mediumFrame);
      expect(resolved.select(Detent.full).px, fullFrame);
    });

    test('an unknown or absent request opens at the smallest', () {
      expect(resolved.select(null).px, resolved.min.px);
      expect(
        resolved.select(Detent.fraction(const Fraction(0.25))).px,
        resolved.min.px,
      );
    });
  });

  group('value semantics', () {
    test('sets written twice are the same set', () {
      // A rebuild hands the panel a new DetentSet every frame. If this compared
      // unequal the panel would read every frame as a set change and snap.
      const a = DetentSet([Detent.full, Detent.medium]);
      final b = _rebuilt();
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, a);
    });

    test('a fresh fractional detent does not read as a set change', () {
      final a = _fractionSet(0.4);
      final b = _fractionSet(0.4);
      expect(identical(a.detents.first, b.detents.first), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(_fractionSet(0.5)));
    });

    test('order and membership are both part of the identity', () {
      const a = DetentSet([Detent.full, Detent.medium]);
      expect(a, isNot(const DetentSet([Detent.medium, Detent.full])));
      expect(a, isNot(const DetentSet([Detent.full])));
      expect(
        a,
        isNot(const DetentSet([Detent.full, Detent.height(DetentValue(180))])),
      );
      expect(a, isNot(const Object()));
    });

    test('a set says what it holds', () {
      expect(
        const DetentSet([Detent.full, Detent.medium]).toString(),
        'DetentSet([Detent.full, Detent.medium])',
      );
    });

    test('resolved sets compare by their snaps', () {
      final a = descending.resolve(baseline);
      final b = const DetentSet([
        Detent.height(DetentValue(180)),
        Detent.medium,
        Detent.full,
      ]).resolve(baseline);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, a);
      expect(a, isNot(const DetentSet([Detent.full]).resolve(baseline)));
      expect(a, isNot(descending.resolve(kIPhone17.panelBaseline())));
      expect(a, isNot(const Object()));
    });

    test('a resolved set says what it resolved to', () {
      expect(
        const DetentSet([Detent.full]).resolve(baseline).toString(),
        'ResolvedDetents(Detent.full: 812.0, dismissible: false)',
      );
    });
  });
}
