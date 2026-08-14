import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/layout.dart';
import 'package:shits/src/geometry/units.dart';

import '../fixtures/devices.dart';

void main() {
  group('value semantics', () {
    test('two passes over the same space are one value', () {
      // What this buys: a model can early-out of a layout pass on a single ==,
      // rather than comparing five fields by hand and leaving a note to make the
      // class immutable one day.
      expect(kIPhone17Pro.layout(), kIPhone17Pro.layout());
      expect(kIPhone17Pro.layout().hashCode, kIPhone17Pro.layout().hashCode);
      final same = kIPhone17Pro.layout();
      expect(same, same);
      expect(kIPhone17Pro.layout(), isNot(const Object()));
    });

    test('every field is part of the identity', () {
      final base = kIPhone17Pro.layout();
      expect(base, isNot(kIPhone17.layout()));
      expect(
        base,
        isNot(
          kIPhone17Pro.layout(viewInsets: const EdgeInsets.only(bottom: 336)),
        ),
      );
      expect(
        base,
        isNot(kIPhone17Pro.layout(contentExtent: const Extent(420))),
      );
      expect(
        base,
        isNot(kIPhone17Pro.layout(textDirection: TextDirection.rtl)),
      );
      expect(
        base,
        isNot(
          PanelLayout(
            baseline: base.baseline,
            viewInsets: base.viewInsets,
            contentExtent: base.contentExtent,
            devicePixelRatio: 2,
            textDirection: base.textDirection,
          ),
        ),
      );
    });

    test('an unmeasured pass differs from a measured one', () {
      expect(kIPhone17Pro.layout().contentExtent, isNull);
      expect(
        kIPhone17Pro.layout(contentExtent: const Extent(420)).contentExtent!.px,
        420.0,
      );
    });

    test('says what it is', () {
      expect(
        kIPhone17Pro.layout().toString(),
        'PanelLayout(PanelBaseline(safeSpan: 778.0, viewportSpan: 874.0, '
        'attachedPadding: 34.0, crossSpan: 402.0, isCompactHeight: false, '
        'spanAxis: vertical), viewInsets: EdgeInsets.zero, contentExtent: null, '
        'devicePixelRatio: 3.0, textDirection: ltr)',
      );
    });
  });

  group('the keyboard lives here and nowhere else', () {
    test('a raised keyboard is visible in the layout', () {
      // The other half of KB6: the inset is not hidden from the package, it is
      // hidden from detent arithmetic. A keyboard policy is a real feature and
      // it reads this field.
      final open = kIPhone17Pro.layout(
        viewInsets: const EdgeInsets.only(bottom: 336),
      );
      expect(open.viewInsets.bottom, 336.0);
      expect(open.baseline, kIPhone17Pro.layout().baseline);
    });
  });

  group('guards', () {
    test('a zero device pixel ratio is refused, not tolerated', () {
      // Every pixel-level comparison in the layer divides by it, and zero makes
      // them all quietly false.
      expect(
        () => PanelLayout(
          baseline: kIPhone17Pro.panelBaseline(),
          viewInsets: EdgeInsets.zero,
          contentExtent: null,
          devicePixelRatio: 0,
          textDirection: TextDirection.ltr,
        ),
        throwsAssertionError,
      );
    });
  });
}
