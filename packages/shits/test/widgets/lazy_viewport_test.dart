import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/shits.dart';

import 'harness.dart';

// ============================================================================
// The claim this package makes out loud, and the one test nothing below the
// widget layer could write: **a lazy list inside a panel gets a viewport equal
// to the panel's visible extent, and builds only that much.**
//
// It is the user-visible half of the render layer's frame-based geometry.
// `render_panel_test.dart` proves the render object lays its child out at the
// resolved extent with tight constraints; this proves what that buys, through a
// real `ListView.builder` with a real `ScrollPosition` — that a peeking sheet
// over a thousand rows builds fifteen of them, and that the number moves with
// the panel while the panel is still moving.
//
// A translate-only core is the implementation this is written against, and it
// is the one every prior art reaches for because it is cheaper: lay the content
// out once at the largest detent and move it. DESIGN.md §1.1 names the cost in
// the `Extent` vs `EdgeOffset` row — *"an inner `ListView` gets a viewport of
// `H` while `v·H` is on screen"* — and every assertion below is a number that
// differs between the two.
//
// The rows are 48pt, which divides none of the frames: 469.68 / 48 is 9.785 and
// 812 / 48 is 16.9, so no assertion here can be satisfied by a count that
// happens to land on a boundary.
// ============================================================================

/// Flutter's own default, and the reason the built count is not simply the
/// viewport over the row height: a viewport builds its cache too.
const double _cacheExtent = 250;

/// The row height. See the header for why it is 48 and not 50.
const double _rowExtent = 48;

void main() {
  useIPhone17Pro();

  testWidgets('a lazy list is given the panel\'s visible extent, and builds '
      'only that much', (tester) async {
    final built = <int>{};
    final controller = PanelController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      onIPhone17Pro(
        Panel(
          detents: kPeekSet,
          initialDetent: Detent.medium,
          controller: controller,
          child: ListView.builder(
            itemCount: 1000,
            itemExtent: _rowExtent,
            itemBuilder: (context, index) {
              built.add(index);
              return Text('row $index');
            },
          ),
        ),
      ),
    );

    ScrollPosition position() =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position;

    // 469.68, and not 812. This is the whole claim in one number: a
    // translate-only core hands the list the largest detent's frame and lets the
    // panel move it, so the list's own idea of how much of it is on screen is
    // 342pt too large at every stop below the largest.
    expect(position().viewportDimension, closeTo(kMediumFrame, 1e-9));

    // And it acted on it. A viewport builds what it can show plus its cache, so
    // the bound is (469.68 + 250) / 48 = 15 rows; the same list in an 812pt
    // viewport builds 23. Written against the viewport it reports rather than
    // against a transcribed constant, because the first assertion is what pins
    // that number and one place to change it is enough.
    expect(
      built.length * _rowExtent,
      lessThan(position().viewportDimension + _cacheExtent + _rowExtent),
    );
    expect(
      built.length * _rowExtent,
      lessThan(kFullFrame),
      reason:
          'a list laid out at the largest detent would have built past 812pt '
          'of rows for a panel showing 469.68 of them',
    );
    final atMedium = built.length;

    // Mid-motion, which is the half a still frame cannot see. The list's
    // viewport tracks the panel frame by frame rather than being resized once
    // at each end of the settle.
    controller.animateTo(Detent.full);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      position().viewportDimension,
      greaterThan(kMediumFrame + 1),
      reason: 'the panel has not moved, so this proves nothing about motion',
    );
    expect(position().viewportDimension, lessThan(kFullFrame - 1));
    expect(position().viewportDimension, closeTo(extentIn(tester), 1e-9));

    await tester.pumpAndSettle();

    expect(position().viewportDimension, closeTo(kFullFrame, 0.5));
    expect(
      built.length,
      greaterThan(atMedium),
      reason: 'a taller panel shows more rows, so it has to have built more',
    );
  });

  testWidgets('and a shorter detent does not un-build what it already has', (
    tester,
  ) async {
    // The other direction, and the reason the count is a `Set`: a viewport that
    // shrinks stops *painting* rows, and whether it rebuilds them is the
    // framework's business rather than ours. What must not happen is the
    // opposite claim — a panel shrinking to a peek and the list still reporting
    // 812pt of viewport, which is what a cached viewport dimension looks like.
    final controller = PanelController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      onIPhone17Pro(
        Panel(
          detents: kPeekSet,
          initialDetent: Detent.full,
          controller: controller,
          child: ListView.builder(
            itemCount: 1000,
            itemExtent: _rowExtent,
            itemBuilder: (context, index) => Text('row $index'),
          ),
        ),
      ),
    );

    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .viewportDimension,
      closeTo(kFullFrame, 1e-9),
    );

    controller.animateTo(const Detent.height(DetentValue(180)));
    await tester.pumpAndSettle();

    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .viewportDimension,
      closeTo(kPeekFrame, 0.5),
    );
  });
}
