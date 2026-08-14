import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/units.dart';

import '../fixtures/devices.dart';

/// The scroll velocity Flutter itself would report for a pointer moving at
/// [pointer], in a scrollable laid out on [axis] under [textDirection].
///
/// Derived from the framework's own convention rather than from `PanelAnchor`:
/// `ScrollPosition.pixels` rises as the finger moves toward the axis' origin, and
/// a horizontal scrollable's axis mirrors in RTL. This is the oracle the sign
/// table is checked against, so the round-trip tests below are not two
/// statements of the same formula.
ScrollVelocity _flutterScrollVelocity(
  Offset pointer,
  Axis axis,
  TextDirection textDirection,
) => switch (axis) {
  Axis.vertical => ScrollVelocity(-pointer.dy),
  Axis.horizontal => ScrollVelocity(
    textDirection == TextDirection.ltr ? -pointer.dx : pointer.dx,
  ),
};

void main() {
  const directions = [TextDirection.ltr, TextDirection.rtl];

  group('axes', () {
    test('span axis', () {
      expect(PanelAnchor.bottom.spanAxis, Axis.vertical);
      expect(PanelAnchor.top.spanAxis, Axis.vertical);
      expect(PanelAnchor.center.spanAxis, Axis.vertical);
      expect(PanelAnchor.leading.spanAxis, Axis.horizontal);
      expect(PanelAnchor.trailing.spanAxis, Axis.horizontal);
    });

    test('only leading and trailing are defined by the reading direction', () {
      expect(PanelAnchor.leading.isDirectional, isTrue);
      expect(PanelAnchor.trailing.isDirectional, isTrue);
      expect(PanelAnchor.bottom.isDirectional, isFalse);
      expect(PanelAnchor.top.isDirectional, isFalse);
      expect(PanelAnchor.center.isDirectional, isFalse);
    });
  });

  group('growth direction', () {
    test('is fixed for the screen-anchored placements', () {
      for (final direction in directions) {
        expect(PanelAnchor.bottom.resolve(direction), AxisDirection.up);
        expect(PanelAnchor.top.resolve(direction), AxisDirection.down);
        expect(PanelAnchor.center.resolve(direction), AxisDirection.up);
      }
    });

    test('mirrors for the reading-anchored placements', () {
      expect(
        PanelAnchor.leading.resolve(TextDirection.ltr),
        AxisDirection.right,
      );
      expect(
        PanelAnchor.leading.resolve(TextDirection.rtl),
        AxisDirection.left,
      );
      expect(
        PanelAnchor.trailing.resolve(TextDirection.ltr),
        AxisDirection.left,
      );
      expect(
        PanelAnchor.trailing.resolve(TextDirection.rtl),
        AxisDirection.right,
      );
    });
  });

  group('baselineOf', () {
    for (final device in kMeasuredDevices) {
      test(
        '${device.name}: a vertical anchor subtracts both vertical insets',
        () {
          for (final anchor in [
            PanelAnchor.bottom,
            PanelAnchor.top,
            PanelAnchor.center,
          ]) {
            expect(
              anchor.baselineOf(device.size, device.viewPadding).px,
              device.baseline,
              reason: '$anchor on ${device.name}',
            );
          }
        },
      );
    }

    test('a horizontal anchor subtracts both horizontal insets', () {
      const landscape = Size(874, 402);
      const viewPadding = EdgeInsets.only(left: 62, right: 62, bottom: 21);
      for (final anchor in [PanelAnchor.leading, PanelAnchor.trailing]) {
        expect(anchor.baselineOf(landscape, viewPadding).px, 874 - 62 - 62);
      }
    });

    test('never goes negative when the insets swallow the viewport', () {
      expect(
        PanelAnchor.bottom
            .baselineOf(
              const Size(402, 40),
              const EdgeInsets.only(top: 62, bottom: 34),
            )
            .px,
        0.0,
      );
    });
  });

  group('attachedPadding', () {
    test('is the inset at the attachment edge', () {
      const viewPadding = EdgeInsets.fromLTRB(10, 62, 20, 34);
      for (final direction in directions) {
        expect(
          PanelAnchor.bottom.attachedPadding(viewPadding, direction).px,
          34.0,
        );
        expect(
          PanelAnchor.top.attachedPadding(viewPadding, direction).px,
          62.0,
        );
      }
      expect(
        PanelAnchor.leading.attachedPadding(viewPadding, TextDirection.ltr).px,
        10.0,
      );
      expect(
        PanelAnchor.leading.attachedPadding(viewPadding, TextDirection.rtl).px,
        20.0,
      );
      expect(
        PanelAnchor.trailing.attachedPadding(viewPadding, TextDirection.ltr).px,
        20.0,
      );
      expect(
        PanelAnchor.trailing.attachedPadding(viewPadding, TextDirection.rtl).px,
        10.0,
      );
    });

    test('is zero for a centred panel, which has no attachment edge', () {
      for (final direction in directions) {
        expect(
          PanelAnchor.center
              .attachedPadding(const EdgeInsets.all(34), direction)
              .px,
          0.0,
        );
      }
    });
  });

  group('signs', () {
    const upward = Offset(0, -1200);
    const rightward = Offset(1200, 0);

    test('a rising finger grows a sheet and shrinks a top sheet', () {
      expect(
        PanelAnchor.bottom.fromPointer(upward, TextDirection.ltr).isGrowing,
        isTrue,
      );
      expect(
        PanelAnchor.center.fromPointer(upward, TextDirection.ltr).isGrowing,
        isTrue,
      );
      expect(
        PanelAnchor.top.fromPointer(upward, TextDirection.ltr).isGrowing,
        isFalse,
      );
    });

    test('a rightward finger grows a drawer in LTR and a rail in RTL', () {
      expect(
        PanelAnchor.leading.fromPointer(rightward, TextDirection.ltr).isGrowing,
        isTrue,
      );
      expect(
        PanelAnchor.leading.fromPointer(rightward, TextDirection.rtl).isGrowing,
        isFalse,
      );
      expect(
        PanelAnchor.trailing
            .fromPointer(rightward, TextDirection.ltr)
            .isGrowing,
        isFalse,
      );
      expect(
        PanelAnchor.trailing
            .fromPointer(rightward, TextDirection.rtl)
            .isGrowing,
        isTrue,
      );
    });

    test('the cross-axis component of a pointer velocity is ignored', () {
      expect(
        PanelAnchor.bottom
            .fromPointer(const Offset(999, -1200), TextDirection.ltr)
            .pxPerSecond,
        1200.0,
      );
      expect(
        PanelAnchor.leading
            .fromPointer(const Offset(1200, 999), TextDirection.ltr)
            .pxPerSecond,
        1200.0,
      );
    });

    test(
      'pointer and scroll conventions agree, for every anchor and direction',
      () {
        // The one test that would catch an even number of sign inversions: the
        // panel-space velocity a finger implies, converted back into scroll
        // space, must equal what Flutter would have measured for that finger.
        const pointers = [
          Offset(0, -1200),
          Offset(0, 1200),
          Offset(-1200, 0),
          Offset(1200, 0),
        ];
        for (final anchor in PanelAnchor.values) {
          for (final direction in directions) {
            for (final pointer in pointers) {
              final viaPanel = anchor.toScroll(
                anchor.fromPointer(pointer, direction),
                direction,
              );
              expect(
                viaPanel.pxPerSecond,
                _flutterScrollVelocity(
                  pointer,
                  anchor.spanAxis,
                  direction,
                ).pxPerSecond,
                reason: '$anchor, $direction, $pointer',
              );
            }
          }
        }
      },
    );

    test('the scroll sign table, written out', () {
      // The table itself, not a round trip through it. `toScroll(fromScroll(v))`
      // multiplies by the sign twice, and sign squared is 1 for every sign, so
      // it passed with the whole table inverted — as did asserting that
      // `fromScroll` ignores the TextDirection it is handed, which `_scrollSign`
      // does by construction. Neither could go red.
      //
      // Which way each sign goes, from Flutter's convention: a rising
      // `ScrollPosition.pixels` means the content moved toward the axis' origin,
      // which is the finger moving up (vertical) or toward the reading start
      // (horizontal). That grows a bottom sheet and a dialog, shrinks a top
      // sheet, shrinks a drawer at the reading-start edge, and grows a rail at
      // the reading-end edge.
      const rising = ScrollVelocity(1200);
      const expected = {
        PanelAnchor.bottom: 1200.0,
        PanelAnchor.center: 1200.0,
        PanelAnchor.top: -1200.0,
        PanelAnchor.leading: -1200.0,
        PanelAnchor.trailing: 1200.0,
      };
      for (final anchor in PanelAnchor.values) {
        for (final direction in directions) {
          expect(
            anchor.fromScroll(rising, direction).pxPerSecond,
            expected[anchor],
            reason: '$anchor, $direction',
          );
          // The inverse carries the same sign, which is what makes a fling
          // handed back across the seam arrive pointing the way it left.
          expect(
            anchor
                .toScroll(ExtentVelocity(expected[anchor]!), direction)
                .pxPerSecond,
            rising.pxPerSecond,
            reason: '$anchor, $direction',
          );
        }
      }
    });

    test(
      'the scroll sign agrees with the finger, in both reading directions',
      () {
        // The claim `_scrollSign` makes by ignoring its TextDirection: a
        // horizontal scrollable flips its axis in RTL at the same moment a leading
        // anchor changes edge, so the two mirrors cancel. Asserting that the
        // parameter is inert cannot fail; asserting that the *result* still
        // matches the finger, against the framework's own convention, can — and
        // does, in RTL, the moment the sign starts mirroring.
        const pointers = [
          Offset(0, -1200),
          Offset(0, 1200),
          Offset(-1200, 0),
          Offset(1200, 0),
        ];
        for (final anchor in PanelAnchor.values) {
          for (final direction in directions) {
            for (final pointer in pointers) {
              final scroll = _flutterScrollVelocity(
                pointer,
                anchor.spanAxis,
                direction,
              );
              expect(
                anchor.fromScroll(scroll, direction).pxPerSecond,
                anchor.fromPointer(pointer, direction).pxPerSecond,
                reason: '$anchor, $direction, $pointer',
              );
            }
          }
        }
      },
    );

    test('a scroll delta moves the extent the way a scroll velocity does', () {
      for (final anchor in PanelAnchor.values) {
        for (final direction in directions) {
          expect(
            anchor.extentDeltaFromScrollDelta(37, direction),
            anchor.fromScroll(const ScrollVelocity(37), direction).pxPerSecond,
            reason: '$anchor, $direction',
          );
        }
      }
    });
  });

  group('rectOf', () {
    final layout = kIPhone17Pro.layout();
    final baseline = layout.baseline;

    test('pins three edges and moves only the leading one', () {
      final small = PanelAnchor.bottom.rectOf(
        const Extent(234),
        EdgeOffset.zero,
        layout,
      );
      final full = PanelAnchor.bottom.rectOf(
        const Extent(812),
        EdgeOffset.zero,
        layout,
      );
      expect(small, const Rect.fromLTRB(0, 874 - 234, 402, 874));
      expect(full, const Rect.fromLTRB(0, 62, 402, 874));
      expect(small.left, full.left);
      expect(small.right, full.right);
      expect(small.bottom, full.bottom);
    });

    test('an edge offset translates the whole frame without resizing it', () {
      final rect = PanelAnchor.bottom.rectOf(
        const Extent(812),
        const EdgeOffset(200),
        layout,
      );
      expect(rect.height, 812.0);
      expect(rect.bottom, 874 - 200);
    });

    test('the gap above a full sheet is the top inset, and only that', () {
      // G3: iOS leaves a .large sheet exactly at viewPadding.top, 62pt down.
      //
      // Why 62 and not 96: `Detent.full` resolves to 778, which is G2's measured
      // maxDetentValue, and 778 is a *content* span inside the sheet's own safe
      // area. The frame that holds it is one attachment padding taller —
      // `frameOf` adds the home indicator's 34pt — so the frame is 812 and its
      // top edge is 874 − 812 = 62. G2, G3 and G6 reconcile in exactly one way,
      // and this is it; 96 was G2 read as a frame, which put the sheet 34pt
      // below where the platform puts it.
      //
      // Two numbers this deliberately is not: 96, the gap when the value is
      // mistaken for the frame, and 69.92, the 0.08 x height top gap Flutter's
      // own Cupertino sheet uses, which is ~8pt shy here and ~33pt shy on an
      // SE-class device.
      final rect = PanelAnchor.bottom.rectOf(
        baseline.frameOf(Detent.full.resolve(baseline)!),
        EdgeOffset.zero,
        layout,
      );
      expect(rect.top, 62.0);
      expect(rect.top, kIPhone17Pro.viewPadding.top);
      expect(rect.top, isNot(96.0));
      expect(rect.top, isNot(closeTo(0.08 * 874, 0.01)));
    });

    for (final device in kMeasuredDevices) {
      test('${device.name}: a full sheet stops at the top inset', () {
        final deviceLayout = device.layout();
        final deviceBaseline = deviceLayout.baseline;
        final rect = PanelAnchor.bottom.rectOf(
          deviceBaseline.frameOf(Detent.full.resolve(deviceBaseline)!),
          EdgeOffset.zero,
          deviceLayout,
        );
        expect(rect.top, device.viewPadding.top);
        expect(rect.bottom, device.size.height);
      });
    }

    test('a layout measured for another anchor is refused', () {
      // The baseline knows which axis it measured and rectOf never asked. A
      // drawer's baseline on a 17 Pro carries viewportSpan 402 and crossSpan
      // 874, so a bottom sheet asked for its rect against it came back
      // Rect.fromLTRB(0, -376, 874, 402): 874 wide on a 402-wide device, top
      // edge off the screen, and finite and non-empty enough that nothing
      // downstream could tell it from a real rect.
      final drawerLayout = kIPhone17Pro.layout(anchor: PanelAnchor.leading);
      expect(
        () => PanelAnchor.bottom.rectOf(
          const Extent(778),
          EdgeOffset.zero,
          drawerLayout,
        ),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(
              contains('bottom'),
              contains('vertical'),
              contains('horizontal'),
            ),
          ),
        ),
      );
    });

    test('the other four anchors say so, loudly', () {
      for (final anchor in PanelAnchor.values.where(
        (a) => a != PanelAnchor.bottom,
      )) {
        expect(
          () => anchor.rectOf(const Extent(778), EdgeOffset.zero, layout),
          throwsA(
            isA<UnimplementedError>().having(
              (e) => e.message,
              'message',
              allOf(contains(anchor.name), contains('CrossAxisFit')),
            ),
          ),
          reason: '$anchor',
        );
      }
    });
  });
}
