import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/baseline.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';

import '../fixtures/devices.dart';

void main() {
  group('the measured table', () {
    for (final device in kMeasuredDevices) {
      test('${device.name}: safeSpan is the measured maxDetentValue', () {
        expect(device.panelBaseline().safeSpan.px, device.baseline);
      });

      test('${device.name}: the viewport span is not the baseline', () {
        final baseline = device.panelBaseline();
        expect(baseline.viewportSpan.px, device.size.height);
        expect(
          baseline.viewportSpan.px - baseline.safeSpan.px,
          device.viewPadding.top + device.viewPadding.bottom,
        );
      });

      test('${device.name}: the cross span is the full width', () {
        expect(device.panelBaseline().crossSpan, device.size.width);
      });
    }

    test('the two safe-area geometries produce different baselines', () {
      // If this ever passes trivially the table has lost a row and the 47pt
      // top-inset device is no longer covered.
      expect(kMeasuredDevices.map((d) => d.viewPadding.top).toSet().length, 2);
    });
  });

  group('attachedPadding', () {
    test('is the home indicator when the sheet reaches the bottom', () {
      expect(kIPhone17Pro.panelBaseline().attachedPadding.px, 34.0);
    });

    test('is nothing when the panel floats', () {
      expect(
        kIPhone17Pro
            .panelBaseline(attachment: EdgeAttachment.floating)
            .attachedPadding
            .px,
        0.0,
      );
    });

    test('is nothing for a centred panel, however it is attached', () {
      expect(
        kIPhone17Pro
            .panelBaseline(anchor: PanelAnchor.center)
            .attachedPadding
            .px,
        0.0,
      );
    });
  });

  group('frameOf is the only way from a value to a frame', () {
    final attached = kIPhone17Pro.panelBaseline();
    final floating = kIPhone17Pro.panelBaseline(
      attachment: EdgeAttachment.floating,
    );

    test('adds the attachment padding, which is G6 verbatim', () {
      // The SDK header: `.height(200)` gives a sheet whose height is
      // 200 + safeAreaInsets.bottom when edge-attached.
      expect(attached.frameOf(const DetentValue(200)).px, 234.0);
    });

    test('adds nothing when the panel floats clear of the edge', () {
      expect(floating.frameOf(const DetentValue(200)).px, 200.0);
    });

    test('reconciles G2, G3 and G6 on the measured device', () {
      // G2: the full value is the measured maxDetentValue, exactly.
      final value = Detent.full.resolve(attached)!;
      expect(value.px, kIPhone17Pro.baseline);
      // G6 applied to it: the frame is one home indicator taller.
      expect(attached.frameOf(value).px, 812.0);
      // G3 falls out: the top edge of that frame is the top inset, 62 — where
      // iOS puts a .large sheet. All three hold, and they hold only together.
      expect(
        kIPhone17Pro.size.height - attached.frameOf(value).px,
        kIPhone17Pro.viewPadding.top,
      );
    });

    for (final device in kMeasuredDevices) {
      test('${device.name}: the full frame leaves exactly the top inset', () {
        final baseline = device.panelBaseline();
        final frame = baseline.frameOf(Detent.full.resolve(baseline)!);
        expect(device.size.height - frame.px, device.viewPadding.top);
      });
    }

    test('saturates at zero rather than producing an inverted rect', () {
      // A detent that refuses its padding may legitimately carry a negative
      // value — a 10pt frame against a 34pt home indicator has −24pt of content
      // clear of it. A negative *frame* is what reaches PanelAnchor.rectOf as a
      // rect with its bottom above its top.
      expect(attached.frameOf(const DetentValue(-24)).px, 10.0);
      expect(attached.frameOf(const DetentValue(-100)).px, 0.0);
      expect(floating.frameOf(const DetentValue(-100)).px, 0.0);
    });
  });

  group('the span axis decides which numbers are which', () {
    test('a horizontal anchor measures across the viewport', () {
      const landscape = Size(874, 402);
      const viewPadding = EdgeInsets.only(left: 62, right: 62, bottom: 21);
      final baseline = PanelBaseline.from(
        viewport: landscape,
        viewPadding: viewPadding,
        anchor: PanelAnchor.leading,
        textDirection: TextDirection.ltr,
      );
      expect(baseline.spanAxis, Axis.horizontal);
      expect(baseline.safeSpan.px, 874 - 62 - 62);
      expect(baseline.viewportSpan.px, 874.0);
      expect(baseline.crossSpan, 402.0);
      expect(baseline.attachedPadding.px, 62.0);
    });

    test('a right-to-left drawer takes its padding from the other side', () {
      final baseline = PanelBaseline.from(
        viewport: const Size(874, 402),
        viewPadding: const EdgeInsets.only(left: 62, right: 0),
        anchor: PanelAnchor.leading,
        textDirection: TextDirection.rtl,
      );
      expect(baseline.attachedPadding.px, 0.0);
    });
  });

  group('compact height', () {
    test('portrait is not compact, on every measured device', () {
      for (final device in kMeasuredDevices) {
        expect(
          device.panelBaseline().isCompactHeight,
          isFalse,
          reason: device.name,
        );
      }
    });

    test('an iPhone in landscape is', () {
      // Rotated arithmetic, not a measured row: only the height matters here,
      // and every iPhone lands between 320 and 440 on its side.
      for (final device in kMeasuredDevices) {
        final baseline = PanelBaseline.from(
          viewport: Size(device.size.height, device.size.width),
          viewPadding: EdgeInsets.zero,
          anchor: PanelAnchor.bottom,
          textDirection: TextDirection.ltr,
        );
        expect(baseline.isCompactHeight, isTrue, reason: device.name);
      }
    });

    test('the threshold sits between the tallest landscape iPhone and the '
        'shortest portrait one', () {
      expect(kCompactHeightThreshold, greaterThan(440));
      expect(kCompactHeightThreshold, lessThanOrEqualTo(568));
    });

    test('is decided by height even when the panel spans the width', () {
      final baseline = PanelBaseline.from(
        viewport: const Size(874, 402),
        viewPadding: EdgeInsets.zero,
        anchor: PanelAnchor.leading,
        textDirection: TextDirection.ltr,
      );
      expect(baseline.isCompactHeight, isTrue);
    });
  });

  group('the keyboard cannot reach a detent', () {
    // KB6, proved by construction rather than by discipline. PanelBaseline.from
    // takes no viewInsets, so a keyboard has no argument to arrive through.
    const detents = DetentSet([
      Detent.height(DetentValue(180)),
      Detent.medium,
      Detent.full,
      Detent.fraction(Fraction(0.25)),
    ]);

    test('a 336pt keyboard changes no resolved detent by a single bit', () {
      final closed = kIPhone17Pro.layout();
      final open = kIPhone17Pro.layout(
        viewInsets: const EdgeInsets.only(bottom: 336),
      );

      final before = detents.resolve(closed.baseline);
      final after = detents.resolve(open.baseline);

      expect(before.snaps.length, after.snaps.length);
      for (var i = 0; i < before.snaps.length; i++) {
        expect(before.snaps[i].$1, after.snaps[i].$1);
        expect(
          before.snaps[i].$2.px,
          equals(after.snaps[i].$2.px),
          reason: 'detent ${before.snaps[i].$1} moved with the keyboard',
        );
      }
      expect(before, after);
    });

    test('the two passes share one baseline value', () {
      // The structural half of the same claim: the keyboard changed the layout
      // and could not change the thing detents resolve against.
      final closed = kIPhone17Pro.layout();
      final open = kIPhone17Pro.layout(
        viewInsets: const EdgeInsets.only(bottom: 336),
      );
      expect(closed.baseline, open.baseline);
      expect(closed.baseline.hashCode, open.baseline.hashCode);
      expect(closed, isNot(open));
    });

    test('padding, which does collapse, is not a field either', () {
      // MediaQueryData.padding.bottom drops from 34 to 0 with the keyboard up.
      // Handing it in where viewPadding belongs is the mistake; the assertion is
      // that it produces a visibly different baseline rather than a quietly
      // shorter detent, so a test at this layer catches it.
      final wrong = PanelBaseline.from(
        viewport: kIPhone17Pro.size,
        viewPadding: const EdgeInsets.only(top: 62),
        anchor: PanelAnchor.bottom,
        textDirection: TextDirection.ltr,
      );
      expect(wrong.safeSpan.px, 812.0);
      expect(wrong, isNot(kIPhone17Pro.panelBaseline()));
    });
  });

  group('degenerate viewports', () {
    test('insets larger than the viewport give up rather than go negative', () {
      final baseline = PanelBaseline.from(
        viewport: const Size(402, 40),
        viewPadding: const EdgeInsets.only(top: 62, bottom: 34),
        anchor: PanelAnchor.bottom,
        textDirection: TextDirection.ltr,
      );
      expect(baseline.safeSpan.px, 0.0);
      expect(Detent.full.resolve(baseline)!.px, 0.0);
      // The frame is still the attachment padding, which is the honest answer:
      // the safe area is gone, the home indicator is not.
      expect(baseline.frameOf(Detent.full.resolve(baseline)!).px, 34.0);
    });
  });

  group('value semantics', () {
    test('equal parts are equal baselines', () {
      expect(kIPhone17Pro.panelBaseline(), kIPhone17Pro.panelBaseline());
      expect(
        kIPhone17Pro.panelBaseline().hashCode,
        kIPhone17Pro.panelBaseline().hashCode,
      );
      final same = kIPhone17Pro.panelBaseline();
      expect(same, same);
      expect(kIPhone17Pro.panelBaseline(), isNot(kIPhone17.panelBaseline()));
      expect(kIPhone17Pro.panelBaseline(), isNot(const Object()));
    });

    test('every field is part of the identity', () {
      const base = PanelBaseline(
        safeSpan: Baseline(778),
        viewportSpan: ViewportExtent(874),
        attachedPadding: Extent(34),
        crossSpan: 402,
        isCompactHeight: false,
        spanAxis: Axis.vertical,
      );
      const variants = [
        PanelBaseline(
          safeSpan: Baseline(763),
          viewportSpan: ViewportExtent(874),
          attachedPadding: Extent(34),
          crossSpan: 402,
          isCompactHeight: false,
          spanAxis: Axis.vertical,
        ),
        PanelBaseline(
          safeSpan: Baseline(778),
          viewportSpan: ViewportExtent(844),
          attachedPadding: Extent(34),
          crossSpan: 402,
          isCompactHeight: false,
          spanAxis: Axis.vertical,
        ),
        PanelBaseline(
          safeSpan: Baseline(778),
          viewportSpan: ViewportExtent(874),
          attachedPadding: Extent(0),
          crossSpan: 402,
          isCompactHeight: false,
          spanAxis: Axis.vertical,
        ),
        PanelBaseline(
          safeSpan: Baseline(778),
          viewportSpan: ViewportExtent(874),
          attachedPadding: Extent(34),
          crossSpan: 393,
          isCompactHeight: false,
          spanAxis: Axis.vertical,
        ),
        PanelBaseline(
          safeSpan: Baseline(778),
          viewportSpan: ViewportExtent(874),
          attachedPadding: Extent(34),
          crossSpan: 402,
          isCompactHeight: true,
          spanAxis: Axis.vertical,
        ),
        PanelBaseline(
          safeSpan: Baseline(778),
          viewportSpan: ViewportExtent(874),
          attachedPadding: Extent(34),
          crossSpan: 402,
          isCompactHeight: false,
          spanAxis: Axis.horizontal,
        ),
      ];
      for (final variant in variants) {
        expect(base, isNot(variant), reason: '$variant');
      }
    });

    test('says what it is', () {
      expect(
        kIPhone17Pro.panelBaseline().toString(),
        'PanelBaseline(safeSpan: 778.0, viewportSpan: 874.0, '
        'attachedPadding: 34.0, crossSpan: 402.0, isCompactHeight: false, '
        'spanAxis: vertical)',
      );
    });
  });
}
