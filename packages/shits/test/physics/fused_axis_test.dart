import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/physics/fused_axis.dart';

import '../fixtures/devices.dart';
// The frame constants live with the scroll harness; the axis is physics now,
// but the numbers it is measured against are the same ones the arbiter uses.
import '../scroll/harness.dart';

// ============================================================================
// The coordinate a fling lives on, before anything flings along it.
//
// Pure maths over `geometry/`, so plain `test`s — which is also the argument
// for the file being on `imports_test.dart`'s widget-free list. DESIGN.md §6
// files it under `physics/` and it is in `scroll/` only because `physics/` was
// committed first; keeping it unable to reach a `BuildContext` is what makes
// the eventual move a file move.
//
// Every number below comes off the iPhone 17 Pro and the MVP's detent set: the
// panel rests at 214, 469.68 or 812, so its travel is 598 and the seam sits
// there. A content of 2000 puts the far end at 2598. None of those is a
// multiple or a half of another, which is what stops an assertion being
// satisfied by an implementation that confused two of them.
// ============================================================================

ResolvedDetents get _peek => kPeekSet.resolve(kIPhone17Pro.panelBaseline());

FusedAxis axis({double scrollMax = 2000, ResolvedDetents? detents}) =>
    FusedAxis(detents: detents ?? _peek, scrollMin: 0, scrollMax: scrollMax);

void main() {
  group('the two halves and the seam between them', () {
    test('the panel takes the travel and the content takes the rest', () {
      final a = axis();
      expect(a.panelTravel.px, closeTo(kFullFrame - kPeekFrame, 1e-9));
      expect(a.scrollableDistance, 2000);
      expect(a.seam.px, closeTo(598, 1e-9));
      expect(a.end.px, closeTo(2598, 1e-9));
    });

    test('a single-detent panel puts the seam at the origin', () {
      // S5 on this axis: no travel, so every fling is a scroll and no branch
      // anywhere says so. Worth pinning because a "panelTravel" that fell back
      // to something non-zero for a degenerate set would make a single-detent
      // sheet resize under a fling.
      final a = axis(detents: kSingleSet.resolve(kIPhone17Pro.panelBaseline()));
      expect(a.panelTravel.px, 0);
      expect(a.seam.px, 0);
      expect(a.end.px, 2000);
    });

    test(
      'a content shorter than its viewport gives the panel the whole axis',
      () {
        final a = axis(scrollMax: 0);
        expect(a.scrollableDistance, 0);
        expect(a.end, a.seam);
      },
    );

    test('a content whose start is not zero measures from its own start', () {
      // Every other row in this file leaves `scrollMin` at zero, where
      // `scrollMax - scrollMin` and `scrollMax + scrollMin` are the same number
      // and so is `scrollPixels - scrollMin`. A `CustomScrollView` with a centre
      // sliver has a negative start and a `NestedScrollView`'s inner list a
      // positive one, so the origin is a real quantity and not a constant this
      // type may fold away.
      final a = FusedAxis(detents: _peek, scrollMin: 100, scrollMax: 2100);
      expect(a.scrollableDistance, 2000);
      expect(a.end.px, closeTo(2598, 1e-9));
      // The content sitting *at* its own start is the seam, not 100px past it.
      expect(
        a.positionOf(const Extent(kFullFrame), 100).px,
        closeTo(a.seam.px, 1e-9),
      );
      expect(a.split(a.seam).scrollPixels, 100);
    });

    test('a viewport that has not measured itself yet reports no distance', () {
      // A lazy viewport reports `maxScrollExtent` below `minScrollExtent` for
      // the frame before it knows how long its content is. Unsaturated, that
      // puts `end` below `seam` and makes `split` answer a scroll offset
      // outside the content's own bounds — which reaches `forcePixels` and
      // sticks.
      final a = FusedAxis(detents: _peek, scrollMin: 0, scrollMax: -400);
      expect(a.scrollableDistance, 0);
      expect(a.end, a.seam);
    });
  });

  group('into the coordinate and back', () {
    test('the panel at rest with its content at the start is the origin', () {
      expect(axis().positionOf(Extent(kPeekFrame), 0).px, closeTo(0, 1e-9));
    });

    test(
      'the panel at its largest with the content at the start is the seam',
      () {
        final a = axis();
        expect(
          a.positionOf(const Extent(kFullFrame), 0).px,
          closeTo(a.seam.px, 1e-9),
        );
      },
    );

    test('both at their far ends is the far end', () {
      final a = axis();
      expect(
        a.positionOf(const Extent(kFullFrame), 2000).px,
        closeTo(a.end.px, 1e-9),
      );
    });

    test('the two terms add, in the state where both are off their rails', () {
      // The state `scrollsFirst` and a swapped detent set can both produce: a
      // half-open panel over a scrolled list. Adding is the only extension that
      // stays monotone in both arguments, which is what a simulation over this
      // coordinate needs.
      //
      // This is the row that rules out `max(panel, scroll)` and
      // `panel > 0 ? panel : scroll`, both of which answer correctly on every
      // on-rail state above and give 500 here instead of 586.
      expect(axis().positionOf(const Extent(300), 500).px, closeTo(586, 1e-9));
    });

    test('splitting a position on the rail inverts the mapping', () {
      final a = axis();
      for (final u in [0.0, 1.0, 255.68, 598.0, 599.0, 1500.0, 2598.0]) {
        final parts = a.split(FusedPosition(u));
        expect(
          a.positionOf(parts.extent, parts.scrollPixels).px,
          closeTo(u, 1e-9),
          reason: 'round trip failed at $u',
        );
      }
    });

    test('below the seam the content stays at its start', () {
      final parts = axis().split(const FusedPosition(255.68));
      expect(parts.extent.px, closeTo(469.68, 1e-9));
      expect(parts.scrollPixels, 0);
    });

    test('above the seam the panel stays at its largest', () {
      final parts = axis().split(const FusedPosition(1000));
      expect(parts.extent.px, closeTo(kFullFrame, 1e-9));
      expect(parts.scrollPixels, closeTo(402, 1e-9));
    });

    test('past either end, both halves stay usable', () {
      // A simulation that overshoots writes a valid extent and a valid offset;
      // the overshoot is expressed by the simulation being somewhere the axis
      // is not, rather than by two consumers receiving numbers they cannot use.
      // A negative extent reaches `BoxConstraints.tight` and the framework
      // refuses three layers below whatever produced it.
      final a = axis();
      final under = a.split(const FusedPosition(-400));
      expect(under.extent.px, kPeekFrame);
      expect(under.scrollPixels, 0);

      final over = a.split(const FusedPosition(4000));
      expect(over.extent.px, closeTo(kFullFrame, 1e-9));
      expect(over.scrollPixels, 2000);
    });
  });

  group('where the detents sit on it', () {
    test('every resting height maps below the seam', () {
      final a = axis();
      expect(a.positionOfDetent(Detent.height(const DetentValue(180)))!.px, 0);
      expect(a.positionOfDetent(Detent.medium)!.px, closeTo(255.68, 1e-9));
      expect(a.positionOfDetent(Detent.full)!.px, closeTo(a.seam.px, 1e-9));
    });

    test('a detent that is not in the set has no position', () {
      // Null rather than a fallback. A fling asked to settle at a detent the
      // set no longer contains has lost its destination, and a silently
      // substituted one is how a panel lands somewhere nobody chose.
      expect(
        axis().positionOfDetent(Detent.height(const DetentValue(999))),
        isNull,
      );
    });

    // **There used to be three rows here for a `nearestDetentTo`, and the member
    // is gone.** It had no production caller: `FusedSimulation` picks its
    // destination with `snapTarget` — the panel's own snap policy, over a
    // *projected* landing — and then asks `positionOfDetent` where that detent
    // sits. A nearest-detent search on this axis is a second way to decide the
    // same thing with neither the projection nor the policy window in it, and
    // the properties those rows asserted (a landing crosses more than one stop,
    // ties go to the shorter detent) belong to `ResolvedDetents.nearestTo` and
    // are pinned in `detent_set_test.dart`, where the one tie-break lives.
  });

  test('two axes over the same geometry are equal', () {
    // Value equality, because a fling re-projected after a layout change
    // compares the axis it was built on against the one that is current, and an
    // identity comparison would re-project on every frame.
    expect(axis(), axis());
    expect(axis().hashCode, axis().hashCode);
    expect(axis(scrollMax: 2001), isNot(axis()));
    // And the seam is a fact about the panel alone: a list that grew by a pixel
    // moves the far end and not the crossing, which is why a fling already past
    // the seam needs no re-projection when a lazy viewport finds another
    // screenful.
    expect(axis().seam, axis(scrollMax: 2001).seam);
  });
}
