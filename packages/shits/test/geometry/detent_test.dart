import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/baseline.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/units.dart';

import '../fixtures/devices.dart';

/// The same device on its side.
///
/// Only the compact-height flag is under test here, so the rotated view padding
/// — which nobody measured — is left out rather than guessed at.
PanelBaseline _landscape(DeviceFixture device) => PanelBaseline.from(
  viewport: Size(device.size.height, device.size.width),
  viewPadding: EdgeInsets.zero,
  anchor: PanelAnchor.bottom,
  textDirection: TextDirection.ltr,
);

void main() {
  group('full', () {
    for (final device in kMeasuredDevices) {
      test('${device.name}: is the baseline exactly', () {
        // Measured at ratio 1.0000 on every row. Exact equality, not a
        // tolerance: approximating it is how a package ends up with a top-gap
        // constant that is 8pt wrong on one device and 33pt wrong on another.
        // This is the *value* — what iOS's resolvedValue(in:) returns. The frame
        // that holds it is one attachment padding taller, and
        // `baseline_test.dart` asserts that the frame leaves the top inset.
        expect(
          Detent.full.resolve(device.panelBaseline())!.px,
          device.baseline,
        );
      });
    }

    test('is never inactive', () {
      expect(Detent.full.resolve(kIPhone17Pro.panelBaseline()), isNotNull);
      expect(Detent.full.resolve(_landscape(kIPhone17Pro)), isNotNull);
    });

    test('and a height detent asking for the same span agrees with it', () {
      // A1's headline case. These resolved to 778 and 812 while each kind
      // decided for itself whether to add the padding, so a set holding both had
      // a largest stop 34pt above the largest stop it was told existed.
      final baseline = kIPhone17Pro.panelBaseline();
      expect(
        Detent.height(DetentValue(kIPhone17Pro.baseline)).resolve(baseline)!.px,
        Detent.full.resolve(baseline)!.px,
      );
      expect(
        baseline
            .frameOf(
              Detent.height(
                DetentValue(kIPhone17Pro.baseline),
              ).resolve(baseline)!,
            )
            .px,
        baseline.frameOf(Detent.full.resolve(baseline)!).px,
      );
    });
  });

  group('medium', () {
    test('is 0.56 of the baseline — the rule, exactly', () {
      // The rule is the measured constant, and it is asserted as an identity
      // rather than within a window: `0.56 * baseline` and nothing else.
      for (final device in kMeasuredDevices) {
        expect(
          Detent.medium.resolve(device.panelBaseline())!.px,
          0.56 * device.baseline,
          reason: device.name,
        );
      }
    });

    test('and 435.667 is that rule observed on a 3x grid', () {
      // The measured observation, asserted separately from the rule because the
      // two are not the same claim and cannot both be exact: 0.56 * 778 is
      // 435.68000000000006 in binary floating point, which is 0.013 from the
      // 435.667 the platform reports, so DESIGN.md G4's +/-1e-2 window is
      // unreachable by 3e-3. The tolerance below is half a physical pixel on a
      // 3x display — 0.5/3 = 0.1667 logical px — which is the finest distinction
      // this screen can draw, and it is named here rather than left as a bare
      // number a later reader has to reverse-engineer.
      const gridTolerance = 0.5 / 3;
      expect(
        Detent.medium.resolve(kIPhone17Pro.panelBaseline())!.px,
        closeTo(435.667, gridTolerance),
        reason:
            'half a physical pixel on a 3x screen; the platform rounds '
            '0.56 x 778 = ${0.56 * 778} onto its pixel grid as 435.667',
      );
      expect(0.56 * 778, isNot(closeTo(435.667, 1e-2)));
    });

    test('and it is not 0.5, which is 46pt short', () {
      final baseline = kIPhone17Pro.panelBaseline();
      // Here so that anyone tidying 0.56 into a half fails on this line rather
      // than 46pt later, on a device.
      expect(Detent.fraction(const Fraction(0.5)).resolve(baseline)!.px, 389.0);
      expect(Detent.medium.resolve(baseline)!.px, isNot(389.0));
    });

    for (final device in kMeasuredDevices) {
      test('${device.name}: the ratio is the same constant', () {
        expect(
          Detent.medium.resolve(device.panelBaseline())!.px / device.baseline,
          closeTo(0.56, 1e-12),
        );
      });
    }

    test('is inactive in compact height, which is an answer, not an error', () {
      expect(Detent.medium.resolve(_landscape(kIPhone17Pro)), isNull);
    });

    test('refuses a horizontal panel rather than inventing a number', () {
      final drawer = PanelBaseline.from(
        viewport: const Size(874, 402),
        viewPadding: EdgeInsets.zero,
        anchor: PanelAnchor.leading,
        textDirection: TextDirection.ltr,
      );
      expect(() => Detent.medium.resolve(drawer), throwsAssertionError);
    });
  });

  group('fraction', () {
    final baseline = kIPhone17Pro.panelBaseline();

    test('multiplies the baseline, never the viewport', () {
      expect(Detent.fraction(const Fraction(0.5)).resolve(baseline)!.px, 389.0);
      // 437.0 is the same fraction of the raw 874pt viewport — the substitution
      // the Baseline type exists to refuse.
      expect(
        Detent.fraction(const Fraction(0.5)).resolve(baseline)!.px,
        isNot(437.0),
      );
    });

    test('mirrors a negative fraction rather than clamping it to nothing', () {
      expect(
        Detent.fraction(const Fraction(-0.2)).resolve(baseline)!.px,
        closeTo(155.6, 1e-9),
      );
    });

    test('clamps above the baseline', () {
      expect(
        Detent.fraction(const Fraction(1.5)).resolve(baseline)!.px,
        kIPhone17Pro.baseline,
      );
      expect(
        Detent.fraction(const Fraction(1)).resolve(baseline)!.px,
        Detent.full.resolve(baseline)!.px,
      );
    });

    test('is never inactive', () {
      expect(
        Detent.fraction(const Fraction(0.5)).resolve(_landscape(kIPhone17Pro)),
        isNotNull,
      );
    });
  });

  group('height', () {
    final attached = kIPhone17Pro.panelBaseline();
    final floating = kIPhone17Pro.panelBaseline(
      attachment: EdgeAttachment.floating,
    );

    test('is the content span as written, on either attachment', () {
      // The value is what the author asked for. It is `frameOf` that decides
      // whether a home indicator sits under it, which is why the two baselines
      // agree here and disagree one line down.
      expect(
        Detent.height(const DetentValue(200)).resolve(attached)!.px,
        200.0,
      );
      expect(
        Detent.height(const DetentValue(200)).resolve(floating)!.px,
        200.0,
      );
    });

    test(
      'and the frame absorbs the padding when the panel reaches the edge',
      () {
        // 200pt of content with a 34pt home indicator underneath it.
        final value = Detent.height(const DetentValue(200)).resolve(attached)!;
        expect(attached.frameOf(value).px, 234.0);
        expect(floating.frameOf(value).px, 200.0);
      },
    );

    test('a detent may refuse the padding on its own', () {
      // It refuses by naming a frame, so the value it carries is that frame less
      // the padding the frame still contains — 200pt of sheet with 166pt of it
      // clear of the home indicator.
      final value = Detent.height(
        const DetentValue(200),
        edgeAttached: false,
      ).resolve(attached)!;
      expect(value.px, 166.0);
      expect(attached.frameOf(value).px, 200.0);
    });

    test('and asking for it back is a no-op today', () {
      // Documented deadness: a floating baseline has already zeroed the padding,
      // so `edgeAttached: true` has nothing to opt back into. If a measurement
      // ever shows a floating sheet absorbing the home indicator, this is the
      // assertion that changes, and it changes on the baseline rather than here.
      expect(
        Detent.height(
          const DetentValue(200),
          edgeAttached: true,
        ).resolve(floating)!.px,
        200.0,
      );
      expect(
        attached
            .frameOf(
              Detent.height(
                const DetentValue(200),
                edgeAttached: true,
              ).resolve(attached)!,
            )
            .px,
        234.0,
      );
    });

    test('has no floor', () {
      // iOS imposes no minimum detent, so neither does this: 10 means 10.
      final value = Detent.height(const DetentValue(10)).resolve(attached)!;
      expect(value.px, 10.0);
      expect(floating.frameOf(value).px, 10.0);
      expect(attached.frameOf(value).px, 44.0);
    });

    test('and a frame smaller than its own padding is still that frame', () {
      // The one place a negative value is correct: a 10pt frame against a 34pt
      // home indicator has nothing clear of it. The frame saturates at zero, so
      // nothing inverted reaches a rect.
      final value = Detent.height(
        const DetentValue(10),
        edgeAttached: false,
      ).resolve(attached)!;
      expect(value.px, -24.0);
      expect(attached.frameOf(value).px, 10.0);
    });

    test('has no ceiling either, which is not measured and may be wrong', () {
      // Deliberately unclamped: no measurement covers an absolute detent past
      // the baseline, and inventing a clamp here would be a guess wearing the
      // fixture table's authority. The model clamps the live extent to the
      // resolved set, so the visible failure is a panel that can grow past the
      // safe area rather than one that silently ignores its own detent.
      expect(
        Detent.height(const DetentValue(2000)).resolve(attached)!.px,
        2000.0,
      );
      expect(
        attached
            .frameOf(Detent.height(const DetentValue(2000)).resolve(attached)!)
            .px,
        2034.0,
      );
    });
  });

  group('resolve is the validation boundary', () {
    // A3. An extension type's getter cannot be read in a const constructor's
    // initializer list (`const_eval_extension_type_method`), so none of these
    // can refuse themselves where they are written. `resolve` is where DESIGN.md
    // says validation lives, and it validated nothing.
    final baseline = kIPhone17Pro.panelBaseline();

    test('a negative height is refused, not turned into an inverted rect', () {
      // It resolved to -66 and reached PanelAnchor.rectOf as
      // Rect.fromLTRB(0, 940, 402, 874) — bottom above top, height -66.
      expect(
        () => Detent.height(const DetentValue(-100)).resolve(baseline),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('-100'), contains('inverted rect')),
          ),
        ),
      );
      expect(
        () => Detent.height(const DetentValue(-0.5)).resolve(baseline),
        throwsAssertionError,
      );
      expect(
        () =>
            Detent.height(const DetentValue(double.infinity)).resolve(baseline),
        throwsAssertionError,
      );
      expect(
        () => Detent.height(const DetentValue(double.nan)).resolve(baseline),
        throwsAssertionError,
      );
      // Zero is a height. The floor is a floor, not a refusal.
      expect(Detent.height(DetentValue.zero).resolve(baseline)!.px, 0.0);
    });

    test('a NaN fraction is refused rather than read as Detent.full', () {
      // num.clamp orders NaN above its upper limit, so this resolved to the
      // whole baseline: a division that produced a NaN upstream arrived as a
      // full-height sheet, byte-identical to a deliberate one.
      expect(
        () => Detent.fraction(const Fraction(double.nan)).resolve(baseline),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('NaN'), contains('Detent.full')),
          ),
        ),
      );
      expect(
        () =>
            Detent.fraction(const Fraction(double.infinity)).resolve(baseline),
        throwsAssertionError,
      );
      expect(
        () => Detent.fraction(
          const Fraction(double.negativeInfinity),
        ).resolve(baseline),
        throwsAssertionError,
      );
      // And the clamp still does its own job for finite fractions.
      expect(
        Detent.fraction(const Fraction(1.5)).resolve(baseline)!.px,
        baseline.safeSpan.px,
      );
    });
  });

  group('resolution is pure and repeatable', () {
    test('the same baseline gives the same answer, seven times over', () {
      // iOS invokes its equivalent about seven times in one layout pass.
      final baseline = kIPhone17Pro.panelBaseline();
      const detents = [
        Detent.full,
        Detent.medium,
        Detent.fraction(Fraction(0.33)),
        Detent.height(DetentValue(180)),
      ];
      for (final detent in detents) {
        final first = detent.resolve(baseline);
        for (var i = 0; i < 7; i++) {
          expect(detent.resolve(baseline)?.px, first?.px, reason: '$detent');
        }
      }
    });
  });

  group('value semantics', () {
    test('detents written twice compare equal', () {
      // The rebuild case: a detent set is rebuilt every frame, and a set that
      // compared unequal to itself would re-snap the panel every frame.
      expect(Detent.full, Detent.full);
      expect(Detent.medium, Detent.medium);
      expect(
        Detent.fraction(const Fraction(0.4)),
        Detent.fraction(const Fraction(0.4)),
      );
      expect(
        Detent.height(const DetentValue(180)),
        Detent.height(const DetentValue(180)),
      );
      expect(
        Detent.height(const DetentValue(180), edgeAttached: false),
        Detent.height(const DetentValue(180), edgeAttached: false),
      );
    });

    test('different detents do not', () {
      expect(Detent.full, isNot(Detent.medium));
      expect(Detent.full, isNot(const Object()));
      expect(Detent.medium, isNot(const Object()));
      expect(
        Detent.fraction(const Fraction(0.4)),
        isNot(Detent.fraction(const Fraction(0.5))),
      );
      expect(Detent.fraction(const Fraction(0.4)), isNot(Detent.full));
      expect(
        Detent.height(const DetentValue(180)),
        isNot(Detent.height(const DetentValue(200))),
      );
      expect(
        Detent.height(const DetentValue(180)),
        isNot(Detent.height(const DetentValue(180), edgeAttached: false)),
      );
      expect(Detent.height(const DetentValue(180)), isNot(Detent.medium));
    });

    test('equal detents hash together', () {
      expect(Detent.full.hashCode, Detent.full.hashCode);
      expect(Detent.medium.hashCode, Detent.medium.hashCode);
      expect(Detent.full.hashCode, isNot(Detent.medium.hashCode));
      expect(
        Detent.fraction(const Fraction(0.4)).hashCode,
        Detent.fraction(const Fraction(0.4)).hashCode,
      );
      expect(
        Detent.height(const DetentValue(180)).hashCode,
        Detent.height(const DetentValue(180)).hashCode,
      );
    });

    test('says what it is', () {
      expect(Detent.full.toString(), 'Detent.full');
      expect(Detent.medium.toString(), 'Detent.medium');
      expect(
        Detent.fraction(const Fraction(0.4)).toString(),
        'Detent.fraction(0.4)',
      );
      expect(
        Detent.height(const DetentValue(180)).toString(),
        'Detent.height(180.0)',
      );
      expect(
        Detent.height(const DetentValue(180), edgeAttached: false).toString(),
        'Detent.height(180.0, edgeAttached: false)',
      );
    });
  });
}
