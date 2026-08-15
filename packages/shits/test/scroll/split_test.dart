import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/physics/motion.dart';
import 'package:shits/src/physics/fused_axis.dart';
import 'package:shits/src/physics/fused_simulation.dart';
import 'package:shits/src/scroll/link.dart';
import 'package:shits/src/scroll/policy.dart';

import '../fixtures/devices.dart';
import 'harness.dart';
import 'package:shits/src/physics/momentum.dart';

// ============================================================================
// Who gets the delta.
//
// `capture_test.dart` proves the panel *sees* its content's scrolling. This
// file is what it does with it, and it is the layer's whole reason to exist:
// Flutter's gesture arena cannot express partial consumption, so a sheet and
// the list inside it cannot each win a share of a pointer. Owning the position
// is how the share becomes arithmetic, and arithmetic is what this file pins.
//
// Every test is a plain `test`. The arbiter takes three scalars — where the
// content is and where its ends are — and a model that imports no binding, so
// there is nothing here to pump. That is deliberate: an arbitration matrix is
// only worth having if it is cheap enough to enumerate exhaustively, and a
// matrix of `testWidgets` is not.
//
// The discipline every case below is written under: **before the expectation,
// ask what other implementation would also satisfy it, and if one would, change
// the input.** Where a case survives that question only because of a specific
// number, the number says so in a comment.
// ============================================================================

void main() {
  // ==========================================================================
  // The three values the constructor picks when the app names none of them.
  //
  // A default nobody exercises is not one end of a policy, and until `linkAt`
  // stopped restating them this whole file was arbitrating under values it had
  // passed in itself: `PanelRefreshPolicy.whenFullyOpen` could be swapped for
  // `never` in `link.dart` and `refresh_test.dart` — whose entire subject is
  // that default — stayed green, with no `RefreshIndicator` in any sheet ever
  // firing again. So the harness names none of them, and these three rows read
  // each one back through the behaviour it produces rather than through the
  // field it is stored in.
  // ==========================================================================
  group('the shipped defaults', () {
    test('resizesFromEdge is the scroll policy nobody asked for', () {
      // Both neighbours, because the value is the middle one of three. The
      // first row is refused by `scrollsFirst` and the second is taken by
      // `resizesAlways`, so no other value in the enum answers both.
      final link = linkAt(kMediumFrame);
      expect(link.scrollPolicy, PanelScrollPolicy.resizesFromEdge);
      expect(
        link.panelMayTake(30, FakeContent()),
        isTrue,
        reason: 'scrollsFirst would refuse this one',
      );
      expect(
        link.panelMayTake(30, FakeContent(pixels: 300)),
        isFalse,
        reason: 'resizesAlways would take this one',
      );
    });

    test('whenFullyOpen is the refresh policy nobody asked for', () {
      // The default A6.5 argues for, read back through the two rows that
      // separate it from its neighbours: at the ceiling the list keeps the
      // downward drag (which `never` gives to the panel), and one detent down
      // the panel keeps it (which `always` gives to the list).
      expect(
        linkAt(kFullFrame).refreshPolicy,
        PanelRefreshPolicy.whenFullyOpen,
      );
      expect(
        linkAt(kFullFrame).split(-40, FakeContent()).content,
        -40,
        reason: 'never would hand this to the panel and no indicator would arm',
      );
      expect(
        linkAt(kMediumFrame).split(-40, FakeContent()).panel,
        -40,
        reason: 'always would hand this to the list at every detent',
      );
    });

    test('both is the momentum carry nobody asked for', () {
      // The one policy nothing else in this suite reaches through a link:
      // `fused_ballistic_test.dart` builds its `FusedSimulation`s directly and
      // passes `carry:` on every one of them, so the link's own default is only
      // ever read here and by a real release.
      //
      // A hard throw from the peek with the list at its top projects past the
      // seam. Under `both` it leaves the panel and becomes a scroll, which is
      // what a null destination means; under `none` **and** under
      // `intoPanelOnly` the seam is a wall and the fling snaps to `.full`
      // instead — so one assertion separates the shipped value from both of the
      // others.
      final link = linkAt(kPeekFrame);
      expect(link.momentumCarry, MomentumCarry.both);
      final out = link.flingFor(const ScrollVelocity(3000), FakeContent());
      expect(
        out.destination,
        isNull,
        reason:
            'the throw crossed out of the panel and became the list\'s, which '
            'is the crossing the other two values forbid',
      );
      expect(
        out.seamCrossing,
        isNotNull,
        reason: 'and it really did cross, rather than never reaching the seam',
      );
    });
  });

  // ==========================================================================
  // Sign. Two entry points into one position, measuring the same motion, with
  // opposite conventions — this is where a handoff goes wrong silently, and
  // where the failure reads as "the sheet closes when I scroll up".
  // ==========================================================================
  group('the two sign conventions', () {
    // Every anchor, and the answer for a finger moving toward the content's
    // start. A single-anchor test would be satisfied by `-delta`, which is the
    // right answer for a bottom sheet and the wrong one for three of the five.
    const table = <(PanelAnchor, TextDirection, double)>[
      (PanelAnchor.bottom, TextDirection.ltr, -10.0),
      (PanelAnchor.bottom, TextDirection.rtl, -10.0),
      (PanelAnchor.top, TextDirection.ltr, 10.0),
      (PanelAnchor.top, TextDirection.rtl, 10.0),
      (PanelAnchor.leading, TextDirection.ltr, 10.0),
      // The row that discriminates. An implementation that mirrors for RTL
      // itself gives -10 here and passes every other row — and it would be
      // wrong, because `ScrollDragController.update` has already reversed the
      // delta for `axisDirectionIsReversed` before the position sees it
      // (`scroll_activity.dart:321`). The drawer and its horizontal list mirror
      // together, so the two flips cancel and there is nothing left to do.
      (PanelAnchor.leading, TextDirection.rtl, 10.0),
      (PanelAnchor.trailing, TextDirection.ltr, -10.0),
      (PanelAnchor.trailing, TextDirection.rtl, -10.0),
      (PanelAnchor.center, TextDirection.ltr, -10.0),
    ];

    for (final (anchor, textDirection, expected) in table) {
      test(
        '$anchor in $textDirection: a drag toward the start is $expected',
        () {
          final link = linkAt(
            kMediumFrame,
            anchor: anchor,
            textDirection: textDirection,
            // `Detent.medium` asserts a vertical span axis, so a horizontal
            // anchor cannot use the MVP set. The single set is `.full`, which
            // every baseline has.
            detents: anchor.spanAxis == Axis.vertical ? kPeekSet : kSingleSet,
          );
          expect(link.extentDeltaOfDrag(dragDown(10)), expected);
        },
      );
    }

    test('a scroll delta is the negation of a drag delta', () {
      // `applyUserOffset` subtracts its delta from `pixels` (:131) and
      // `pointerScroll` adds its own to it (:219-222). One position, one
      // gesture, two signs — and a trackpad that opens the sheet when the
      // finger says close is what confusing them looks like.
      //
      // Asserted with a magnitude as well as a relation, because "both are
      // zero" satisfies the relation alone.
      final link = linkAt(kMediumFrame);
      expect(link.extentDeltaOfScroll(10), -link.extentDeltaOfDrag(10));
      expect(link.extentDeltaOfScroll(10).abs(), 10);
    });

    for (final anchor in PanelAnchor.values) {
      for (final textDirection in TextDirection.values) {
        test('$anchor in $textDirection round-trips both conversions', () {
          // Invertibility alone would be satisfied by the identity, which the
          // table above already rules out. What this adds is the claim the
          // conversions are *involutions* — true only because every anchor's
          // scroll sign is exactly ±1 — so the day an anchor needs a scale
          // factor, the call site that would silently keep working fails here.
          final link = linkAt(
            kMediumFrame,
            anchor: anchor,
            textDirection: textDirection,
            detents: anchor.spanAxis == Axis.vertical ? kPeekSet : kSingleSet,
          );
          expect(link.dragDeltaOfExtent(link.extentDeltaOfDrag(37.5)), 37.5);
          expect(
            link.scrollDeltaOfExtent(link.extentDeltaOfScroll(37.5)),
            37.5,
          );
        });
      }
    }
  });

  // ==========================================================================
  // The policy table, on its own. No rooms, no clamping, no refresh — just the
  // question the SDK header asks.
  // ==========================================================================
  group('who is entitled to the delta', () {
    group('resizesFromEdge — the shipped default and the measured one', () {
      test('S1: growing from the content\'s start is the panel\'s', () {
        final link = linkAt(kMediumFrame);
        expect(link.panelMayTake(30, FakeContent()), isTrue);
      });

      test('S2: growing away from the start is the content\'s', () {
        // The row that rules out "the panel takes everything it has room for":
        // there is a detent above 469.68, so a room-only implementation says
        // yes here and is wrong.
        final link = linkAt(kMediumFrame);
        expect(link.panelMayTake(30, FakeContent(pixels: 300)), isFalse);
      });

      test('growing at the largest detent is the content\'s', () {
        // And this is the row that rules out "the panel takes it whenever the
        // content is at its start". Both halves of the precondition are
        // load-bearing and neither alone is the rule.
        final link = linkAt(kFullFrame);
        expect(link.panelMayTake(30, FakeContent()), isFalse);
      });

      test('S6: shrinking from the content\'s start is the panel\'s', () {
        final link = linkAt(
          kMediumFrame,
          refreshPolicy: PanelRefreshPolicy.never,
        );
        expect(link.panelMayTake(-30, FakeContent()), isTrue);
      });

      test('shrinking away from the start is the content\'s', () {
        // Rules out "shrinking is always the panel's", which is
        // `resizesAlways`. The list scrolls back to its top first.
        final link = linkAt(
          kMediumFrame,
          refreshPolicy: PanelRefreshPolicy.never,
        );
        expect(link.panelMayTake(-30, FakeContent(pixels: 300)), isFalse);
      });

      test('S5: a single-detent panel never takes a growing delta', () {
        // No neighbour above, so scrolling simply scrolls — and there is no
        // special case in the arbiter that says so. This is the test that the
        // *absence* of a branch is correct behaviour rather than an oversight.
        final link = linkAt(kFullFrame, detents: kSingleSet);
        expect(link.panelMayTake(30, FakeContent()), isFalse);
      });
    });

    group('resizesAlways — the panel wins whatever the offset', () {
      test('shrinking from a scrolled list is still the panel\'s', () {
        // The one cell that differs from `resizesFromEdge`, and therefore the
        // only assertion that proves this value does anything.
        final link = linkAt(
          kMediumFrame,
          scrollPolicy: PanelScrollPolicy.resizesAlways,
          refreshPolicy: PanelRefreshPolicy.never,
        );
        expect(link.panelMayTake(-30, FakeContent(pixels: 300)), isTrue);
      });

      test('growing from a scrolled list is still the panel\'s', () {
        final link = linkAt(
          kMediumFrame,
          scrollPolicy: PanelScrollPolicy.resizesAlways,
        );
        expect(link.panelMayTake(30, FakeContent(pixels: 300)), isTrue);
      });

      test('growing at the largest detent is still the content\'s', () {
        // The ceiling is not a policy. There is nothing above the largest
        // detent to grow into, under any of the three.
        final link = linkAt(
          kFullFrame,
          scrollPolicy: PanelScrollPolicy.resizesAlways,
        );
        expect(link.panelMayTake(30, FakeContent()), isFalse);
      });
    });

    group('scrollsFirst — the other end of the policy', () {
      for (final (name, delta, content) in <(String, double, FakeContent)>[
        ('growing at the start', 30.0, FakeContent()),
        ('growing scrolled', 30.0, FakeContent(pixels: 300)),
        ('shrinking at the start', -30.0, FakeContent()),
        ('shrinking scrolled', -30.0, FakeContent(pixels: 300)),
      ]) {
        test('$name is the content\'s', () {
          // All four, because "never" is the claim and three of four would be
          // satisfied by a policy that merely resembles it.
          final link = linkAt(
            kMediumFrame,
            scrollPolicy: PanelScrollPolicy.scrollsFirst,
            refreshPolicy: PanelRefreshPolicy.never,
          );
          expect(link.panelMayTake(delta, content), isFalse);
        });
      }
    });
  });

  // ==========================================================================
  // The two edge predicates, and why only one of them has a tolerance.
  // ==========================================================================
  group('the edges', () {
    test('the content is at its start exactly, with no tolerance', () {
      final link = linkAt(kMediumFrame);
      expect(link.contentIsAtStart(FakeContent()), isTrue);
      // A tenth of a millimetre of scroll is still scroll. An implementation
      // with an epsilon here passes the first row and fails this one — and it
      // would be wrong, because `applyBoundaryConditions` pins a resting
      // position exactly at its edge, so a non-zero offset is a real one.
      expect(link.contentIsAtStart(FakeContent(pixels: 0.0001)), isFalse);
      // Overscrolled past the top is still at the top for our purposes: a list
      // already bouncing off its start is not somewhere the panel should
      // decline to take over from.
      expect(link.contentIsAtStart(FakeContent(pixels: -20)), isTrue);
    });

    test('and "its start" is the content\'s own, not zero', () {
      // Every fixture above rests at `minScrollExtent == 0`, where "at its
      // start" and "at zero" are the same number and half a dozen wrong
      // expressions agree. A `NestedScrollView`'s inner list starts at a
      // positive offset and a `CustomScrollView` with a centre sliver at a
      // negative one, so a predicate measured from zero says a list sitting on
      // its own top is 100px into itself — and the panel then never takes over
      // from a list that has already run out.
      //
      // Three rows: at the start, before it, and past it.
      final link = linkAt(kMediumFrame);
      expect(
        link.contentIsAtStart(FakeContent(pixels: 100, minScrollExtent: 100)),
        isTrue,
      );
      expect(
        link.contentIsAtStart(FakeContent(pixels: 80, minScrollExtent: 100)),
        isTrue,
        reason: 'overscrolled past its own start is still at it',
      );
      expect(
        link.contentIsAtStart(FakeContent(pixels: 105, minScrollExtent: 100)),
        isFalse,
      );
    });

    test('the panel is on its ceiling to half a physical pixel', () {
      // The reading A6.5 does not name, and the one that matters. A spring
      // approaches its destination asymptotically, so a settle that stopped a
      // tenth of a pixel short leaves a panel the user has finished opening
      // reporting itself not open — and under the default refresh policy that
      // is a `RefreshIndicator` that silently does not fire.
      //
      // The device is 3x, so half a physical pixel is 0.1667. The two rows
      // either side of it are what rules out both an exact comparison and a
      // round 1.0pt slop.
      expect(linkAt(kFullFrame).isAtCeiling, isTrue);
      expect(linkAt(kFullFrame - 0.1).isAtCeiling, isTrue);
      expect(linkAt(kFullFrame - 0.5).isAtCeiling, isFalse);
      expect(linkAt(kMediumFrame).isAtCeiling, isFalse);
      // And **not** a panel rubber-banded above its largest detent, which is the
      // difference between "standing on the ceiling" and "as open as it gets".
      // It is the narrower reading both callers want: a panel held 90pt past
      // `.full` has somewhere for a downward drag to go, so the refresh veto
      // steps aside, and its fused term is larger than the travel, so the
      // release is off the rail.
      expect(linkAt(kFullFrame + 0.1).isAtCeiling, isTrue);
      expect(linkAt(kFullFrame + 90).isAtCeiling, isFalse);
    });
  });

  // ==========================================================================
  // The two rooms, asked directly. `split` only ever consults them through the
  // leader-keeps rule, which swallows the difference between a room of 5 and a
  // room of 205 — so every one of these numbers is invisible from the matrix
  // below and has to be pinned here.
  // ==========================================================================
  group('the rooms', () {
    test('the content measures to whichever end the direction points at', () {
      // **A start that is not zero is the whole test.** With `minScrollExtent`
      // at 0, `pixels - minScrollExtent` and `pixels + minScrollExtent` are the
      // same number and so are half a dozen other wrong expressions. A
      // `CustomScrollView` with a centre sliver has a negative start and a
      // `NestedScrollView`'s inner list a positive one, so this is a shape the
      // package will meet rather than one invented to break a mutant.
      final link = linkAt(kMediumFrame);
      final content = FakeContent(
        pixels: 105,
        minScrollExtent: 100,
        maxScrollExtent: 2000,
      );
      expect(link.contentRoomFor(-30, content), 5);
      expect(link.contentRoomFor(30, content), 1895);
    });

    test('and the end it measures to is chosen in scroll space', () {
      // Identical to choosing it in extent space for `bottom`, `center` and
      // `trailing`, and inverted for `top` and `leading` — which is why every
      // other row in this file is blind to the difference. A top sheet grows
      // when its list scrolls *back* toward its start, so the room a growing
      // delta has is the 5px above the content's start and not the 1895 below
      // it. Getting this the extent way round is a landmine for the anchor work
      // rather than a bug today, and it costs one row to disarm.
      final link = linkAt(300, anchor: PanelAnchor.top);
      expect(
        link.extentDeltaOfScroll(1),
        -1,
        reason: 'the premise: this anchor inverts scroll space against extent',
      );
      final content = FakeContent(
        pixels: 105,
        minScrollExtent: 100,
        maxScrollExtent: 2000,
      );
      expect(link.contentRoomFor(30, content), 5);
      expect(link.contentRoomFor(-30, content), 1895);
    });

    test('and saturates at zero rather than reporting a negative room', () {
      // Both ends, because a list can be overscrolled past either one and a
      // negative room would hand the leader a share pointing backwards.
      final link = linkAt(kMediumFrame);
      expect(link.contentRoomFor(-30, FakeContent(pixels: -20)), 0);
      expect(link.contentRoomFor(30, FakeContent(pixels: 2100)), 0);
    });

    test('the panel measures to the end of its own travel', () {
      // From 300, which is between two detents, so the two answers are 512 and
      // 86 — neither of them the travel, the delta, or each other.
      final link = linkAt(300);
      expect(link.panelRoomFor(30), closeTo(kFullFrame - 300, 1e-9));
      expect(link.panelRoomFor(-30), closeTo(300 - kPeekFrame, 1e-9));
    });

    test('a list whose start is not zero still hands over at its start', () {
      // The same in-one-delta handoff as the 5px row below, on a content whose
      // start is 100. An implementation that measured from zero gives the list
      // all 30 and the panel nothing.
      final link = linkAt(kFullFrame, refreshPolicy: PanelRefreshPolicy.never);
      final split = link.split(
        -30,
        FakeContent(pixels: 105, minScrollExtent: 100),
      );
      expect(split.content, closeTo(-5, 1e-9));
      expect(split.panel, closeTo(-25, 1e-9));
    });
  });

  // ==========================================================================
  // What a release is built out of. `fused_ballistic_test.dart` owns the
  // simulation's shape; these two rows own the numbers the link feeds it, and
  // both are invisible from there because every fixture in that file builds its
  // own axis with a zero start and the framework's own tolerance.
  // ==========================================================================
  group('the fused release is built from the content that is there', () {
    test('the axis spans the content from its own start', () {
      // With `minScrollExtent` at zero, `scrollMax - scrollMin` and `scrollMax`
      // are the same number. A `NestedScrollView`'s inner list starts at a
      // positive offset, and an axis that assumed zero would project every
      // fling on a coordinate 100px too long — the seam would still be right
      // and the landing would not, so the sheet would settle on the wrong
      // detent only for the content shapes nobody tested.
      final link = linkAt(kMediumFrame);
      final axis = link.axisFor(
        FakeContent(pixels: 105, minScrollExtent: 100, maxScrollExtent: 2000),
      );
      expect(axis.scrollableDistance, 1900);
      expect(
        axis.seam.px,
        closeTo(kFullFrame - kPeekFrame, 1e-9),
        reason: 'the seam is the panel\'s travel and does not move with it',
      );
      expect(axis.end.px, closeTo(kFullFrame - kPeekFrame + 1900, 1e-9));
    });

    test('the fling stops when this display can no longer show it moving', () {
      // `Tolerance.defaultTolerance` is calibrated for a 0..1 route animation;
      // over a span in logical pixels it runs a fling's tail for seconds after
      // the last frame that could show a difference. So the tolerance is half a
      // physical pixel of the display the panel is on — 0.1667 at 3x — and the
      // arithmetic is a division.
      //
      // Multiplying instead gives 1.5, which is five physical pixels: the fling
      // would park up to a pixel and a half short of the detent it chose, on
      // every release.
      final link = linkAt(kMediumFrame);
      final finest = 0.5 / kIPhone17Pro.devicePixelRatio;
      final fling = link.flingFor(const ScrollVelocity(-900), FakeContent());
      expect(fling.tolerance.distance, closeTo(finest, 1e-12));
      expect(fling.tolerance.velocity, closeTo(finest, 1e-12));

      // And the behaviour that number buys, so this is not a test of an
      // expression: at the first instant the fling is within a whole logical
      // pixel of its destination it is still running, because a pixel is three
      // physical pixels of visible gap.
      final target = link
          .axisFor(FakeContent())
          .positionOfDetent(fling.destination!)!
          .px;
      var t = 0.0;
      while (t < 10 && (fling.x(t) - target).abs() > 1.0) {
        t += 1 / 240;
      }
      expect(t, lessThan(10), reason: 'the fling never got near its detent');
      expect(
        fling.isDone(t),
        isFalse,
        reason: 'a pixel of gap at ${fling.x(t)} against a target of $target',
      );
    });
  });

  // ==========================================================================
  // Which pairs the fused coordinate can describe, as the round trip that
  // question *is*.
  //
  // `FusedAxis.positionOf` adds `(extent − min)` and `(pixels − scrollMin)`,
  // and `FusedAxis.split` gives everything below the seam to the panel and
  // everything above it to the content. So the predicate the release needs is
  // not "are both inside their bounds" but "does `split` give back the pair
  // `positionOf` was handed" — and the two differ on exactly the states that
  // teleport, which is why the specification below is the round trip and not a
  // restatement of the implementation's four comparisons.
  // ==========================================================================
  group('the states the fused coordinate can describe', () {
    /// Whether `split(positionOf(extent, pixels))` is the pair it was given.
    bool roundTrips(PanelScrollLink link, PanelScrollDriver content) {
      final axis = link.axisFor(content);
      final back = axis.split(axis.positionOf(link.extent, content.pixels));
      return (back.extent.px - link.extent.px).abs() < 1e-9 &&
          (back.scrollPixels - content.pixels).abs() < 1e-9;
    }

    test('the predicate is the round trip, over the whole grid', () {
      // Every combination of five panel heights and five content offsets,
      // including both bounds of each. An answer that is right on the rails and
      // wrong between them passes any sampling that only visits the rails —
      // which is what a bounds test is.
      for (final height in [
        kPeekFrame - 40,
        kPeekFrame,
        kMediumFrame,
        kFullFrame,
        kFullFrame + 40,
      ]) {
        for (final pixels in [-40.0, 0.0, 500.0, 2000.0, 2040.0]) {
          final link = linkAt(height);
          final content = FakeContent(pixels: pixels);
          expect(
            link.isOnFusedAxis(content),
            roundTrips(link, content),
            reason:
                'isOnFusedAxis disagrees with the round trip at '
                'extent $height, pixels $pixels',
          );
        }
      }
    });

    test('neither on its rail is refused, and it is the teleport', () {
      // The state finding 1 of the adversarial review is about, and the one a
      // bounds test calls legal: both halves comfortably inside their own
      // ranges, and neither of them pinned. The sum is 255.68 + 500, and `split`
      // reads all 598 of the panel's travel out of it — so one frame of a
      // release moves the panel up 342.32 and the list down the same, from a
      // finger lift with no throw in it.
      final link = linkAt(kMediumFrame);
      final content = FakeContent(pixels: 500);
      expect(link.isOnFusedAxis(content), isFalse);

      final axis = link.axisFor(content);
      final back = axis.split(axis.positionOf(link.extent, content.pixels));
      expect(back.extent.px, closeTo(kFullFrame, 1e-9));
      expect(
        back.scrollPixels,
        closeTo(500 - (kFullFrame - kMediumFrame), 1e-9),
      );
    });

    test('the content on its rail is enough, at any height in the travel', () {
      for (final height in [kPeekFrame, kMediumFrame, kFullFrame]) {
        expect(linkAt(height).isOnFusedAxis(FakeContent(pixels: 0)), isTrue);
      }
    });

    test('and so is the panel on its ceiling, at any offset in the range', () {
      for (final pixels in [0.0, 500.0, 2000.0]) {
        expect(
          linkAt(kFullFrame).isOnFusedAxis(FakeContent(pixels: pixels)),
          isTrue,
        );
      }
    });

    test('the ceiling is read to half a physical pixel, like every other', () {
      // The same tolerance `_isAtCeiling` gives the refresh policy, for the same
      // reason: a spring approaches its destination asymptotically, and a settle
      // that stopped a tenth of a pixel short would un-fuse the next release —
      // silently, and only sometimes.
      final content = FakeContent(pixels: 500);
      expect(linkAt(kFullFrame - 0.1).isOnFusedAxis(content), isTrue);
      expect(linkAt(kFullFrame - 1).isOnFusedAxis(content), isFalse);
    });

    test('a single-detent panel is always on the rail', () {
      // Its travel is zero, so the seam sits at the origin and the whole axis is
      // the content's — S5 again, with no branch written for it. The panel's one
      // height is both `min` and `max`, so it is standing on its ceiling by
      // definition and every content offset round-trips.
      final link = linkAt(kFullFrame, detents: kSingleSet);
      for (final pixels in [0.0, 500.0, 2000.0]) {
        expect(link.isOnFusedAxis(FakeContent(pixels: pixels)), isTrue);
      }
    });

    test('an overshoot on either side is off it, whatever the other does', () {
      expect(
        linkAt(kFullFrame).isOnFusedAxis(FakeContent(pixels: -40)),
        isFalse,
        reason: 'an overscrolled list maps past the far end',
      );
      expect(
        linkAt(kFullFrame + 40).isOnFusedAxis(FakeContent(pixels: 0)),
        isFalse,
        reason: 'an overdragged panel maps above the seam, into the content',
      );
    });
  });

  // ==========================================================================
  // The policy, asked about a release rather than about a delta.
  //
  // `split` enforces both policies on every frame of a drag; the release used
  // to consult neither, so a fling moved a panel that every delta before it had
  // been refused. The question is the same table — it is *where* it is asked
  // that is the finding.
  // ==========================================================================
  group('who is entitled to a release', () {
    test('from the content\'s start it is the state the panel is in', () {
      // Nothing new: the release moves the panel first, so `panelMayTakeRelease`
      // is `panelMayTake` here and the two must not drift apart.
      for (final policy in PanelScrollPolicy.values) {
        final link = linkAt(kMediumFrame, scrollPolicy: policy);
        final content = FakeContent();
        for (final delta in [dragUp(1), dragDown(1)]) {
          expect(
            link.panelMayTakeRelease(delta, content),
            link.panelMayTake(delta, content),
            reason: '$policy disagreed about $delta',
          );
        }
      }
    });

    test('from a scrolled list, a release toward the panel asks at the seam', () {
      // The fling has to run the list back to its start before it reaches the
      // panel, so the state to ask about is the one at the seam — the panel at
      // its largest, the content at its own start — and not the one the finger
      // left. Asked about the state it left, every row here answers "yes",
      // because a scrolled list under `resizesFromEdge` refuses the panel and
      // the release was refused for the wrong reason or not at all.
      final scrolled = FakeContent(pixels: 500);
      expect(
        linkAt(
          kFullFrame,
          scrollPolicy: PanelScrollPolicy.scrollsFirst,
        ).panelMayTakeRelease(-1, scrolled),
        isFalse,
        reason: 'the panel is moved only by its handle, its background or code',
      );
      expect(
        linkAt(
          kFullFrame,
          refreshPolicy: PanelRefreshPolicy.always,
        ).panelMayTakeRelease(-1, scrolled),
        isFalse,
        reason: 'the panel never shrinks from a drag on its list',
      );
      expect(
        linkAt(kFullFrame).panelMayTakeRelease(-1, scrolled),
        isFalse,
        reason:
            'the shipped default vetoes a shrink from the top of a fully open '
            'panel, which is what makes RefreshIndicator work — and a release '
            'that ignored it would close the sheet the spinner is on',
      );
      expect(
        linkAt(
          kFullFrame,
          refreshPolicy: PanelRefreshPolicy.never,
        ).panelMayTakeRelease(-1, scrolled),
        isTrue,
        reason:
            'pure S6 still carries momentum across the seam, so MomentumCarry '
            'is not quietly dead',
      );
    });

    test('and a release away from the panel never asks', () {
      // It scrolls away from the seam it would have to cross, so there is no
      // state in which it reaches the panel and nothing for the table to refuse.
      // Refusing it anyway would un-fuse the commonest fling there is.
      for (final policy in PanelScrollPolicy.values) {
        expect(
          linkAt(
            kFullFrame,
            scrollPolicy: policy,
          ).panelMayTakeRelease(1, FakeContent(pixels: 500)),
          isTrue,
          reason: '$policy refused a release that never reaches the panel',
        );
      }
    });
  });

  // ==========================================================================
  // The result is a value, and the two fields are not interchangeable.
  // ==========================================================================
  group('a split is a value', () {
    test('two splits of the same delta are the same split', () {
      // Deliberately not `const`: Dart canonicalises equal constants, so a
      // const pair is compared by `identical` and the field comparison below it
      // is never reached — which is how an `==` that ignored a field would pass.
      final a = PanelScrollSplit(panel: 12, content: 18);
      final b = PanelScrollSplit(panel: 12, content: 18);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.total, 30);
    });

    test('and one that moved the other half is not', () {
      // Both fields, one row each. An equality that compared only the panel's
      // share answers correctly for the first pair and wrongly for the second.
      final split = PanelScrollSplit(panel: 12, content: 18);
      expect(split, isNot(PanelScrollSplit(panel: 18, content: 18)));
      expect(split, isNot(PanelScrollSplit(panel: 12, content: 12)));
    });
  });

  // ==========================================================================
  // The layer says what it is when something has already gone wrong.
  // ==========================================================================
  group('diagnostics', () {
    test('every value in the layer describes itself by its fields', () {
      // Not decoration. These are read from a `ScrollNotification` dump and from
      // a `FlutterError`'s stack — which is what someone reaches for *after*
      // something has failed — so a `toString` that threw, or that printed an
      // instance hash, turns one failure into two.
      expect(
        PanelScrollSplit(panel: 12, content: 18).toString(),
        allOf(contains('12'), contains('18')),
      );
      final axis = FusedAxis(
        detents: kPeekSet.resolve(kIPhone17Pro.panelBaseline()),
        scrollMin: 0,
        scrollMax: 2000,
      );
      expect(axis.toString(), contains('2000'));
      expect(
        FusedSimulation(
          axis: axis,
          from: const FusedPosition(700),
          velocity: -1000,
          motion: const PanelMotion.smooth(),
        ).toString(),
        allOf(contains('700'), contains('-1000'), contains('medium')),
      );
    });
  });

  // ==========================================================================
  // The split itself. Five cases, and the rule that produces all of them:
  // whoever leads takes what it has room for, and the follower takes the rest
  // only if the policy — re-asked in the state the leader would leave — still
  // permits it.
  // ==========================================================================
  group('one delta, two owners', () {
    test('the panel stops at its ceiling and the list takes the rest', () {
      // Panel at 300, between the 214 peek and the 469.68 medium, with 512pt of
      // room below `.full`. A 600pt delta therefore straddles two detents and
      // the ceiling.
      //
      // The numbers are chosen to tell two implementations apart: capping at
      // the *next* detent gives the panel 169.68, capping at the *largest*
      // gives 512. Only the second is right — a hard drag crosses as many
      // stops as it pays for — and at any extent adjacent to `.full` the two
      // answers coincide, which is why the panel starts at 300 and not at 800.
      final link = linkAt(300);
      final split = link.split(600, FakeContent());
      expect(split.panel, closeTo(kFullFrame - 300, 1e-9));
      expect(split.content, closeTo(600 - (kFullFrame - 300), 1e-9));
    });

    test('the list scrolls to its top and the panel shrinks, in one delta', () {
      // Five pixels of scroll left, thirty pixels of finger. iOS does this
      // inside one gesture frame; an implementation that decides once per
      // delta gives the list all thirty and starts shrinking on the *next*
      // frame, which is a visible stall at exactly the moment the list
      // arrives at its top.
      final link = linkAt(kFullFrame, refreshPolicy: PanelRefreshPolicy.never);
      final split = link.split(-30, FakeContent(pixels: 5));
      expect(split.content, closeTo(-5, 1e-9));
      expect(split.panel, closeTo(-25, 1e-9));
    });

    test('a list at its end bounces rather than growing the panel', () {
      // The follower is re-asked and refused. `resizesFromEdge` says the panel
      // grows *from the content\'s start*, and the content is at its far end —
      // so the leftover stays with the list and it overscrolls.
      //
      // This is the row that rules out "the leftover always goes to the
      // follower", which is the obvious reading of the rule and is wrong in
      // exactly this direction.
      final link = linkAt(kMediumFrame);
      final split = link.split(30, FakeContent(pixels: 2000));
      expect(split.content, 30);
      expect(split.panel, 0);
    });

    test(
      'at the smallest detent with the list at its top, the panel keeps it',
      () {
        // Neither has room, and it goes to the panel — which rubber-bands, and
        // once `Detent.dismissed` lands is what carries a dismissal.
        //
        // Handing it to the list instead would put a refresh spinner under a
        // sheet that is being flung away, which is the single worst outcome the
        // refresh argument can produce, and it is what a rule with no
        // "otherwise the leader keeps it" clause does here.
        final link = linkAt(kPeekFrame);
        final split = link.split(-40, FakeContent());
        expect(split.panel, -40);
        expect(split.content, 0);
      },
    );

    test(
      'and it keeps it whether the list was at its top or five pixels above it',
      () {
        // The same gesture as the row above, with the list not quite at its
        // start. It scrolls its five and the panel takes the other 35 — into the
        // band, and once `Detent.dismissed` lands, out of the viewport.
        //
        // The row exists because the two used to disagree: a rule that asked
        // whether the *follower* had room handed this one to the list, so a
        // sheet at its smallest could be flung shut from a list resting at its
        // top and not from the same list five pixels down. Whether a panel can
        // be dismissed is not a fact about where its content happens to be.
        final link = linkAt(kPeekFrame);
        final split = link.split(-40, FakeContent(pixels: 5));
        expect(split.content, closeTo(-5, 1e-9));
        expect(split.panel, closeTo(-35, 1e-9));
      },
    );

    test('resizesAlways carries the panel through its smallest detent', () {
      // The other side of the leader-keeps clause, and the one no row above
      // reaches: the panel *leads*, has run out of travel, and the list has
      // 300px of room. Handing the leftover on because the follower can use it
      // stops the sheet dead at its peek and scrolls the list instead — and
      // once `Detent.dismissed` lands, that is a sheet that cannot be flung
      // shut by the gesture the policy exists to grant.
      //
      // `resizesAlways` is what puts the panel in the lead with a scrolled
      // list; under `resizesFromEdge` the content leads here and the other
      // branch decides.
      final link = linkAt(
        kPeekFrame,
        scrollPolicy: PanelScrollPolicy.resizesAlways,
      );
      final split = link.split(-40, FakeContent(pixels: 300));
      expect(split.panel, -40);
      expect(split.content, 0);
    });

    test(
      'a list with nothing to scroll leaves the whole overdrag to the panel',
      () {
        // Three short rows in a sheet. The panel has 12pt of room below `.full`
        // and the content has none at all, so the panel takes all 30 and the
        // band shapes the last 18.
        //
        // An implementation that caps the panel at its room unconditionally
        // hands 18pt to a list that has no end to bounce off, and the gesture
        // dies against a boundary condition. The `.short()` fixture is the only
        // input that separates the two.
        final link = linkAt(kFullFrame - 12);
        final split = link.split(30, FakeContent.short());
        expect(split.panel, 30);
        expect(split.content, 0);
      },
    );

    test(
      'scrollsFirst gives an unusable delta to the content, not the panel',
      () {
        // "The leader keeps the leftover" means the *permitted* leader. Under
        // `scrollsFirst` the panel is not permitted at all, so a delta neither
        // can use stays with the list and overscrolls it — the panel does not
        // quietly become the fallback for a policy that excluded it.
        final link = linkAt(
          kPeekFrame,
          scrollPolicy: PanelScrollPolicy.scrollsFirst,
          refreshPolicy: PanelRefreshPolicy.never,
        );
        final split = link.split(-40, FakeContent());
        expect(split.content, -40);
        expect(split.panel, 0);
      },
    );

    test('resizesAlways shrinks the panel before scrolling the list back', () {
      // The same two states under the two policies, side by side, because a
      // policy is only worth its name if both ends are tested and the ends
      // have to be the *same* input.
      final always = linkAt(
        kMediumFrame,
        scrollPolicy: PanelScrollPolicy.resizesAlways,
        refreshPolicy: PanelRefreshPolicy.never,
      );
      expect(always.split(-30, FakeContent(pixels: 300)).panel, -30);

      final fromEdge = linkAt(
        kMediumFrame,
        refreshPolicy: PanelRefreshPolicy.never,
      );
      expect(fromEdge.split(-30, FakeContent(pixels: 300)).panel, 0);
    });

    test('nothing is invented and nothing is dropped', () {
      // Conservation, over the whole matrix rather than at one point. Every
      // case above asserts two numbers; this asserts that those two numbers are
      // the only ones — a split that lost 0.0001px per frame to a clamp would
      // pass every case above and drift a panel visibly over a second of
      // dragging.
      for (final policy in PanelScrollPolicy.values) {
        for (final refresh in PanelRefreshPolicy.values) {
          for (final extent in [kPeekFrame, 300.0, kMediumFrame, kFullFrame]) {
            for (final pixels in [-20.0, 0.0, 5.0, 300.0, 2000.0]) {
              for (final delta in [-600.0, -30.0, -0.5, 0.5, 30.0, 600.0]) {
                final link = linkAt(
                  extent,
                  scrollPolicy: policy,
                  refreshPolicy: refresh,
                );
                final split = link.split(delta, FakeContent(pixels: pixels));
                expect(
                  split.total,
                  closeTo(delta, 1e-9),
                  reason:
                      '$policy/$refresh at extent $extent, pixels $pixels, '
                      'delta $delta lost or invented ${split.total - delta}px',
                );
              }
            }
          }
        }
      }
    });

    test('a zero delta moves nobody', () {
      // The frame where a finger rests. It has to be a no-op on both sides or
      // a resting finger walks the panel a rounding error at a time — and it
      // must still be *asked*, because the content\'s own drag controller reads
      // a zero as a stationary sample and keeps its timestamps live from it.
      final link = linkAt(kMediumFrame);
      expect(link.split(0, FakeContent()), PanelScrollSplit.none);
    });
  });
}
