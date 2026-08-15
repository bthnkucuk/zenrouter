import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/scroll/link.dart';
import 'package:shits/src/scroll/policy.dart';

import 'harness.dart';

// ============================================================================
// The two overrides nothing else in this suite reaches, and one of them is the
// hole underneath the whole desktop argument.
//
// `split_test.dart` pins the arbitration and `fused_ballistic_test.dart` pins
// the release; both arrive through `applyUserOffset`, which is one of six
// entry points into an owned `ScrollPosition`. The other two that decide
// anything are here:
//
// - **`pointerScroll`.** `capture_test.dart` measures that the controller is
//   installed on every platform, which is what DESIGN.md §3's desktop argument
//   asks for — and a desktop's actual input is a pointer-scroll signal, which
//   never reaches `applyUserOffset`. Without an override the panel cannot be
//   opened by a wheel at all.
// - **`absorb`.** Flutter replaces a `ScrollPosition` outright when the physics
//   or the controller `runtimeType` changes (`scrollable.dart:686-698`) and
//   disposes the old one immediately after. Everything the panel holds that
//   points at it has to move across, and one of those things — a model activity
//   bound to the old position — cannot be mutated, only replaced.
// ============================================================================

/// Sends one wheel notch of [delta] logical pixels over [location].
///
/// `dy` positive is the direction a wheel scrolls a list *forward*, which for a
/// bottom sheet is also the direction that grows the panel.
Future<void> wheel(WidgetTester tester, Offset location, double delta) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(location));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
  await tester.pump();
}

void main() {
  useIPhone17Pro();

  group('a wheel is not a drag, and it arbitrates anyway', () {
    testWidgets('a notch at the top of the list opens the panel', (
      tester,
    ) async {
      // The hole. `ScrollPositionWithSingleContext.pointerScroll` clamps to the
      // content's own extents and calls `forcePixels` (`:219-234`), so it never
      // reaches `applyUserOffset` and the split never runs: with the capture
      // working perfectly, a trackpad or a wheel scrolls the list and the panel
      // does not move. Reverting the override leaves the panel at 214 and the
      // list at 400.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await wheel(tester, kInsidePanel, 400);

      expect(link.model.extent.px, closeTo(kPeekFrame + 400, 1e-9));
      expect(
        list.position.pixels,
        0,
        reason: 'the panel had room, so the list is not what moved',
      );
    });

    testWidgets('the panel stops at its ceiling and the list takes the rest', (
      tester,
    ) async {
      // The same handoff `split_test.dart` pins for a drag, through the other
      // door and inside one event. From `.medium` a 400pt notch straddles the
      // ceiling: 342.32 of panel and 57.68 of list, two numbers that are neither
      // the notch nor each other — where a test taken at `.full` itself cannot
      // discriminate at all, because there the panel has no room, the list takes
      // all 400, and an implementation with no override answers identically.
      //
      // It must start at a detent rather than 100pt below one: an idle panel is
      // parked at a *detent*, so the first layout pass moves a between-detents
      // extent to wherever its target resolves.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await wheel(tester, kInsidePanel, 400);

      expect(link.model.extent.px, closeTo(kFullFrame, 1e-9));
      expect(
        list.position.pixels,
        closeTo(400 - (kFullFrame - kMediumFrame), 1e-9),
      );
    });

    testWidgets('a notch that does not reach a detent springs back', (
      tester,
    ) async {
      // What "the discrete gesture ends the moment it is delivered" costs, said
      // where somebody will look for it. A wheel has no `Drag` and no lifetime,
      // so the panel settles at the nearest detent as soon as the event is
      // delivered, and 100pt from the peek is still nearest the peek.
      //
      // Both halves are asserted. Without the first the test is satisfied by a
      // panel that never moved, which is exactly the behaviour this override
      // exists to replace.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      await wheel(tester, kInsidePanel, 100);
      expect(link.model.extent.px, closeTo(kPeekFrame + 100, 1e-9));

      await tester.pumpAndSettle();
      expect(link.model.extent.px, closeTo(kPeekFrame, 0.5));
    });

    testWidgets('a notch backwards at the top never reaches us at all', (
      tester,
    ) async {
      // The residual hole, named rather than left to be discovered, and it is
      // above this package: `Scrollable` registers interest in a pointer-scroll
      // only when it would move the *list* (`scrollable.dart:960-964`:
      // `targetScrollOffset != position.pixels`), so a backward notch on a list
      // already at its top is dropped before any override here is consulted. A
      // wheel can open this panel and cannot close it.
      //
      // Asserted as the **asymmetry** rather than as a bare "nothing happened",
      // because nothing-happened is also what a layer that never arbitrates
      // anything reports. The first half of this test is the same event in the
      // other direction, and it moves the panel.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await wheel(tester, kInsidePanel, 200);
      expect(link.model.extent.px, closeTo(kMediumFrame + 200, 1e-9));

      await wheel(tester, kInsidePanel, -200);
      expect(
        link.model.extent.px,
        closeTo(kMediumFrame + 200, 1e-9),
        reason: 'the backward notch was dropped by Scrollable, not by us',
      );
      expect(list.position.pixels, 0);
    });
  });

  group('what a drag publishes while the panel is the thing moving', () {
    testWidgets('the finger\'s direction is reported even with no share', (
      tester,
    ) async {
      // The branch a zero content share takes. `super.applyUserOffset` cannot
      // be called with a zero — `BouncingScrollPhysics.applyPhysicsToUserOffset`
      // opens with `assert(offset != 0.0)`, reachable here and nowhere in the
      // framework — so this is `super`'s first line written out, and the first
      // line is the one that publishes the direction. A `Scrollbar` that
      // stopped hearing about the finger would fade out mid-gesture while the
      // panel is what is moving, and a hiding app bar would stop hiding.
      //
      // The two rows are the framework's own convention, in both directions:
      // `reverse` is a finger moving toward the content's end and `forward` is
      // one moving back. One row alone is satisfied by an implementation that
      // publishes the same answer whatever the finger did.
      final link = linkAt(kMediumFrame);
      final trace = NotificationTrace();
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: trace.listen(longList())),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();

      expect(
        list.position.pixels,
        0,
        reason:
            'the premise: the panel took every pixel and the list took none',
      );
      expect(
        trace.seen
            .whereType<UserScrollNotification>()
            .map((n) => n.direction)
            .toList(),
        [ScrollDirection.reverse, ScrollDirection.forward],
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('and the list is not told to stop building its rows', (
      tester,
    ) async {
      // `ScrollActivity.velocity` is the content's share of the fused fling and
      // is zero below the seam, where the panel is what moves. It is not
      // decoration: `ScrollPhysics.recommendDeferredLoading` compares it
      // against the display's longest physical side and tells every lazy
      // builder in the list to stop building above it. Reporting the panel's
      // speed there — 3,900px/s while a sheet opens — blanks the rows of a list
      // that is standing perfectly still.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await tester.fling(find.byType(ListView), const Offset(0, -300), 4000);
      var below = 0;
      var above = 0;
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final defer = list.position.recommendDeferredLoading(
          tester.element(find.byType(ListView)),
        );
        if (list.position.pixels > list.position.minScrollExtent) {
          above++;
        } else {
          below++;
          expect(
            defer,
            isFalse,
            reason:
                'the list is at ${list.position.pixels} and was told to defer '
                'because the panel is moving at speed',
          );
        }
      }

      expect(below, greaterThan(0), reason: 'no frame below the seam');
      expect(
        above,
        greaterThan(0),
        reason:
            'the fling never crossed, so "zero below the seam" is not a claim '
            'about anything',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('the dump says where the panel is', (tester) async {
      // `debugFillDescription` is what a `ScrollNotification` and a
      // `FlutterError` print, which is what someone reads *after* something has
      // already failed — so a dump that reported the wrong height would send
      // them looking in the wrong place with the evidence in their hand.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      expect(
        list.position.toString(),
        allOf(
          contains('panel: $kMediumFrame'),
          contains('panelActivity: IdlePanelActivity'),
          contains('scrollPolicy: resizesFromEdge'),
          contains('refreshPolicy: whenFullyOpen'),
        ),
      );
    });
  });

  group('what the fused release needs to be true', () {
    testWidgets('a release with the panel exactly on its smallest detent', (
      tester,
    ) async {
      // The mirror of the ceiling row below, and the bound nothing else in the
      // suite touches. `_isOnFusedAxis` is inclusive at all four ends, and the
      // smallest detent is the one a real gesture lands on exactly: a drag
      // down that uses up precisely the panel's remaining travel — 255.68pt
      // from `.medium` — leaves the extent *at* `detents.min` to the last bit.
      //
      // Exclusive, that release is off the axis: the panel goes to its own
      // settle and the list to the framework's ballistic, which is two
      // simulations for one lift, and the panel stops answering
      // `LayoutCorrection.resnap` while it happens.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      final room = link.model.extent.px - link.model.detents.min.px;
      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(Offset(0, room));
      await tester.pump();
      expect(
        link.model.extent.px,
        link.model.detents.min.px,
        reason:
            'the drag has to land on the bound exactly, or a test written '
            'either side of it cannot tell inclusive from exclusive',
      );

      await gesture.up();
      expect(
        link.model.activity,
        isA<ScrollBallisticActivity>(),
        reason:
            'the release was handed to the panel\'s own settle instead of '
            'staying one fling: ${link.model.activity}',
      );

      await tester.pumpAndSettle();
      expect(link.model.extent.px, kPeekFrame);
    });

    testWidgets('a refused release asks about the direction it is going', (
      tester,
    ) async {
      // `goBallistic`'s third path refuses a fling the arbitration already
      // declined — but only when the fling is going *that* way. The velocity
      // arrives in scroll space, and converting it with the drag conversion
      // instead flips its sign, so the release is tested against the opposite
      // direction from the one it is travelling in.
      //
      // `PanelRefreshPolicy.always` is what separates the two answers: it vetoes
      // the panel for a *shrinking* delta from the content's start at every
      // detent, and leaves a growing one alone. So an upward throw is permitted
      // and stays fused, while the same number read as a shrinking delta is
      // refused — and a refusal hands the panel to a settle at zero velocity,
      // which from 567 falls back to `.medium` instead of carrying to `.full`.
      final link = linkAt(
        kMediumFrame,
        refreshPolicy: PanelRefreshPolicy.always,
      );
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await tester.fling(find.byType(ListView), const Offset(0, -100), 2000);
      expect(
        list.position.pixels,
        0,
        reason: 'the premise: the content is still at its start at the release',
      );
      expect(link.model.extent.px, lessThan(kFullFrame));

      await tester.pumpAndSettle();
      expect(
        link.model.extent.px,
        closeTo(kFullFrame, 0.5),
        reason: 'the throw was refused and the panel fell back instead',
      );
    });

    testWidgets('a release with the panel exactly on its ceiling stays fused', (
      tester,
    ) async {
      // The commonest release there is, and the one a boundary written the wrong
      // way loses: drag until the panel is fully open and let go. A drag that
      // uses up the whole travel leaves the extent *exactly* at the largest
      // detent, which is where `_isOnFusedAxis` compares — so an exclusive bound
      // there sends this release down the off-axis path, where the panel is
      // handed to its own settle and the list to the framework's ballistic. Two
      // simulations for one throw, with both endpoints still correct.
      //
      // The assertion is what the model is *holding*, because that is what makes
      // the panel answer `LayoutCorrection.resnap` while the fling runs; the
      // heights either design ends at are the same.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      // A thousand points of finger against 598 of travel, so the panel is
      // capped on its ceiling to the last bit rather than to a tolerance — and
      // thrown, because a release with no velocity is not a fling and parks
      // whichever path it takes.
      await tester.fling(find.byType(ListView), const Offset(0, -1000), 3000);
      expect(
        link.model.extent.px,
        kFullFrame,
        reason: 'a drag past the ceiling leaves the panel on it exactly',
      );
      expect(link.model.activity, isA<ScrollBallisticActivity>());

      await tester.pumpAndSettle();
    });
  });

  // ==========================================================================
  // A release with the panel below its largest detent **and** the list scrolled
  // away from its top — the state `FusedAxis.positionOf`'s sum cannot describe,
  // and the one a bounds test calls legal.
  //
  // Every row measures the frame *after* the release, because that is where the
  // failure lives: the split is not a slow drift, it is one `sample()` writing
  // `extent = min + clamp(sum, 0, travel)` and
  // `scrollPixels = scrollMin + (sum − travel)`, so both quantities move by
  // `min(detents.max − extent, pixels − scrollMin)` in opposite directions on
  // the first frame and every endpoint afterwards is a plausible-looking detent.
  // The three rows are the three ways the state is reachable.
  // ==========================================================================
  group('a release from off the rail moves neither by more than the gesture', () {
    testWidgets('reached programmatically, and lifted with no throw', (
      tester,
    ) async {
      // The ordinary way in, under the shipped policies: a panel moved by code
      // over a list that is already scrolled. `animateTo` from a button, a route
      // handing a sheet back to a smaller detent, `updateConfig` after a
      // rotation — all of them leave a panel below its ceiling with a list that
      // is nowhere near its top, and none of them is exotic.
      //
      // The gesture is 10pt and a plain lift. Before the fix the panel moved
      // 342.32 and the list moved 341.15, from a finger that had travelled ten
      // pixels and thrown nothing.
      final link = linkAt(kFullFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await tester.drag(find.byType(ListView), const Offset(0, -481.17));
      await tester.pumpAndSettle();
      expect(
        list.position.pixels,
        greaterThan(400),
        reason: 'the premise: the list is scrolled a long way from its top',
      );

      link.model.animateTo(Detent.medium);
      await tester.pumpAndSettle();
      expect(
        link.model.extent.px,
        closeTo(kMediumFrame, 0.5),
        reason: 'and the premise\'s other half: the panel is below its ceiling',
      );

      final extentBefore = link.model.extent.px;
      final pixelsBefore = list.position.pixels;
      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        link.model.extent.px - extentBefore,
        closeTo(0, 10),
        reason: 'the panel jumped on the first frame of the release',
      );
      expect(
        list.position.pixels - pixelsBefore,
        closeTo(0, 10),
        reason: 'and the list jumped the same distance the other way',
      );

      await tester.pumpAndSettle();
      expect(link.model.extent.px, closeTo(kMediumFrame, 0.5));
      expect(list.position.pixels, closeTo(pixelsBefore, 10));
    });

    testWidgets('reached by gesture alone, under resizesAlways', (
      tester,
    ) async {
      // No code anywhere near it. `resizesAlways` is the policy for a panel
      // whose detents are modes rather than sizes, and under it a downward drag
      // shrinks the panel while the list keeps its offset — which is exactly the
      // state the fused sum cannot describe, produced by one finger.
      //
      // Measured before the fix: the drag put the panel at 612 and the release
      // put it back at 812 with the list dragged 200 the other way. The release
      // undid the drag the user had just made.
      final link = linkAt(
        kFullFrame,
        scrollPolicy: PanelScrollPolicy.resizesAlways,
      );
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await tester.drag(find.byType(ListView), const Offset(0, -481));
      await tester.pumpAndSettle();
      expect(list.position.pixels, greaterThan(400));
      expect(link.model.extent.px, kFullFrame);

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      final pixelsBefore = list.position.pixels;
      expect(
        link.model.extent.px,
        closeTo(kFullFrame - 200, 1e-9),
        reason: 'the premise: the panel shrank and the list kept its offset',
      );

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        link.model.extent.px,
        lessThan(kFullFrame - 190),
        reason: 'the release grew the panel back toward the ceiling',
      );
      expect(list.position.pixels, closeTo(pixelsBefore, 1));

      await tester.pumpAndSettle();
      expect(
        link.model.extent.px,
        closeTo(kMediumFrame, 0.5),
        reason: 'a release settles at the nearest detent, downward from 612',
      );
      expect(
        list.position.pixels,
        closeTo(pixelsBefore, 1),
        reason: 'and the list was never part of this gesture',
      );
    });

    testWidgets('and from the far end, where the list has run out', (
      tester,
    ) async {
      // The mirror image, and the one that shows the refusal is about the
      // *policy* and not about the arithmetic: the list is at its own end and
      // the panel is at `.medium`, so a fling up belongs entirely to the list —
      // `resizesFromEdge` says a panel only grows from the content's start.
      // Before the fix the panel took the whole throw and opened to 812.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      list.position.jumpTo(list.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final end = list.position.maxScrollExtent;
      expect(link.model.extent.px, closeTo(kMediumFrame, 0.5));

      await tester.fling(find.byType(ListView), const Offset(0, -60), 2000);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        link.model.extent.px,
        closeTo(kMediumFrame, 1),
        reason: 'the panel took a throw thrown at a list that has run out',
      );

      await tester.pumpAndSettle();
      expect(link.model.extent.px, closeTo(kMediumFrame, 0.5));
      expect(
        list.position.pixels,
        closeTo(end, 0.5),
        reason:
            'and the list bounced back off its own end, as it does outside '
            'a panel',
      );
    });
  });

  // ==========================================================================
  // The same table `split_test.dart` enforces on every delta of a drag, through
  // the release — which used to consult neither policy, so all three
  // `PanelScrollPolicy` values and all three `PanelRefreshPolicy` values landed
  // on the same number. Landing on the same number is the shape of the defect:
  // a policy that cannot be told apart from the other two is not being read.
  // ==========================================================================
  group('a fling is refused by the same policies a drag is', () {
    /// Flings a fully open panel's scrolled list downward, and answers where the
    /// panel ends up.
    Future<double> flingDownFromFullyOpen(
      WidgetTester tester,
      PanelScrollLink link,
    ) async {
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));
      list.position.jumpTo(481.17);
      await tester.pumpAndSettle();
      expect(link.model.extent.px, kFullFrame);

      await tester.fling(find.byType(ListView), const Offset(0, 300), 3000);
      await tester.pumpAndSettle();
      return link.model.extent.px;
    }

    testWidgets('scrollsFirst keeps the panel out of it entirely', (
      tester,
    ) async {
      // *"the panel is moved only by its handle, its background, or code"* — and
      // a fling on its list closed it to 214 anyway.
      final link = linkAt(
        kFullFrame,
        scrollPolicy: PanelScrollPolicy.scrollsFirst,
      );
      expect(await flingDownFromFullyOpen(tester, link), kFullFrame);
    });

    testWidgets('resizesAlways lets it through, so the row above is a policy', (
      tester,
    ) async {
      // The other end, and it is what stops "the panel did not move" being
      // satisfied by a release that can never move a panel at all: the same
      // gesture on the same tree, one policy apart, closes the sheet.
      final link = linkAt(
        kFullFrame,
        scrollPolicy: PanelScrollPolicy.resizesAlways,
      );
      expect(
        await flingDownFromFullyOpen(tester, link),
        closeTo(kPeekFrame, 0.5),
      );
    });

    testWidgets('the refresh policy is read at the release too', (
      tester,
    ) async {
      // `PanelRefreshPolicy.always` is *"the panel never shrinks from a drag on
      // its list, at any detent"*, and the shipped default says the same thing
      // at the largest detent — which is the whole of what makes an unmodified
      // `RefreshIndicator` work. A release that ignored both closed the sheet
      // the spinner was sitting on.
      for (final policy in [
        PanelRefreshPolicy.always,
        PanelRefreshPolicy.whenFullyOpen,
      ]) {
        final link = linkAt(kFullFrame, refreshPolicy: policy);
        expect(
          await flingDownFromFullyOpen(tester, link),
          kFullFrame,
          reason: '$policy let a fling shrink a fully open panel',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('and never is pure S6, so momentum still crosses the seam', (
      tester,
    ) async {
      // The row that keeps `MomentumCarry.both` alive rather than quietly
      // deleting it: with no refresh veto in the way, a fling that runs the list
      // out keeps going into the panel and closes it, which is S6 read through a
      // release instead of through a drag.
      final link = linkAt(kFullFrame, refreshPolicy: PanelRefreshPolicy.never);
      expect(
        await flingDownFromFullyOpen(tester, link),
        closeTo(kPeekFrame, 0.5),
      );
    });
  });

  group('a position replaced under a live gesture', () {
    testWidgets('hands the panel across, and the drag keeps going', (
      tester,
    ) async {
      // `scrollable.dart:686-698` replaces the position when the physics
      // `runtimeType` changes and disposes the old one immediately. The model's
      // `ScrollDragActivity` holds that position in a `final` field of a sealed
      // hierarchy this layer does not own, so the binding can only be repointed
      // by replacing the activity — and until it is, `applyUserOffset`'s
      // identity guard refuses every further delta and the panel stops dead
      // under a finger that is still moving.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(link.model.extent.px, closeTo(kMediumFrame + 60, 1e-9));

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(physics: const ClampingScrollPhysics()),
        ),
      );

      expect(
        link.positions,
        hasLength(1),
        reason: 'the disposed position is gone and the new one is registered',
      );
      expect(
        link.model.extent.px,
        closeTo(kMediumFrame + 60, 1e-9),
        reason: 'the swap is not a place for the panel to jump',
      );

      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(
        link.model.extent.px,
        closeTo(kMediumFrame + 100, 1e-9),
        reason: 'the same finger, the same gesture, a different position',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('and the throw at the end of it is still the panel\'s', (
      tester,
    ) async {
      // The half the test above stops one line short of. `absorb` repoints the
      // model's activity, but the `Drag` the recogniser is holding is the object
      // `other.drag` returned and nothing tells the recogniser otherwise — so
      // `PanelDrag.panel` is the activity `beginActivity` disposed, and `end`
      // runs on that: it installs a `ScrollBallisticActivity` bound to the
      // **old** position, which the new position's `goBallistic` then refuses to
      // build a fused activity for, because the fling it finds is not its own.
      //
      // Nothing ticks a model `ScrollBallisticActivity` except
      // `FusedBallisticActivity`, so `isTicking` stays true for ever: measured,
      // the panel sat at 609.68 — 140pt off every detent — through
      // `pumpAndSettle` and through a rotation that re-resolved the detents to
      // `[214, 340]`, still scroll-driven and still answering
      // `LayoutCorrection.freeze`.
      //
      // Two assertions, and they fail on two different mistakes. The endpoint
      // catches a release that lost its velocity — 1875px/s of finger carries
      // the sheet from 590.85 to `.full`, and a release handed to a settle from
      // rest falls back to `.medium`, which is the sheet reversing the gesture
      // the user just made. The terminal state catches the original: a panel
      // still holding a scroll-driven activity after everything has stopped.
      //
      // The timestamps are load-bearing. `TestGesture.moveBy` defaults every
      // event to `Duration.zero`, and the recogniser's `VelocityTracker` reports
      // zero for samples that share an instant — so without them this release is
      // a lift, both readings settle at `.medium`, and the test measures
      // nothing.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(physics: const ClampingScrollPhysics()),
        ),
      );
      for (var frame = 0; frame < 4; frame++) {
        await gesture.moveBy(
          const Offset(0, -30),
          timeStamp: Duration(milliseconds: 16 * (frame + 2)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        link.model.extent.px,
        closeTo(590.85, 0.01),
        reason:
            'the premise: the same finger is still driving the panel. Not the '
            'whole 140pt of it — `_adjustForScrollStartThreshold` eats 18.83 of '
            'the first move, which is iOS\'s motion-start threshold and is one '
            'of the three behaviours `PanelDrag` keeps the framework\'s own '
            'drag underneath for',
      );

      await gesture.up(timeStamp: const Duration(milliseconds: 112));
      expect(
        link.model.activity.velocity.pxPerSecond,
        greaterThan(0),
        reason: 'the release left the panel from rest: ${link.model.activity}',
      );

      await tester.pumpAndSettle();
      expect(
        link.model.extent.px,
        kFullFrame,
        reason: 'the throw was dropped and the sheet fell back instead',
      );
      expect(
        link.model.activity,
        isA<IdlePanelActivity>(),
        reason:
            'the panel is still being driven by a gesture that ended: '
            '${link.model.activity}',
      );
    });

    testWidgets('an overdrag survives the swap exactly', (tester) async {
      // The half a naive re-seed drops. Past the largest detent the extent is
      // what the band is *showing* and the gesture accumulates what the finger
      // is *at*; seeding the replacement from the extent alone would fold the
      // resistance in twice, so the next delta would move the panel by a
      // different amount than the same delta a frame earlier.
      //
      // A short list, because it is the only content that lets the panel
      // overdrag at all: with a list that can scroll, a drag up at the largest
      // detent is the *content's* by S1 and the panel never leaves its rail.
      //
      // 200pt past `.full` is deep enough that the band's compression is larger
      // than the assertion's tolerance: raw 200 shows as about 90.
      final link = linkAt(kFullFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: shortList()),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -200));
      await tester.pump();
      final overdragged = link.model.extent.px;
      expect(overdragged, greaterThan(kFullFrame));
      expect(
        overdragged,
        lessThan(kFullFrame + 200),
        reason:
            'the band resisted it, which is what makes this test mean '
            'something',
      );

      // The same content, one physics apart, so the only thing that changed
      // between the two frames is the position underneath the gesture.
      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: shortList(physics: const ClampingScrollPhysics()),
        ),
      );
      expect(link.model.extent.px, overdragged);

      // And the band still runs from the same accumulated position: coming back
      // 200 lands on `.full` again rather than somewhere the resistance was
      // counted twice.
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      expect(link.model.extent.px, closeTo(kFullFrame, 1e-6));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a fling that loses half its axis settles the panel', (
      tester,
    ) async {
      // A fused fling cannot survive its position being swapped — half the axis
      // has just ceased to exist — so the panel continues on its own at the
      // speed it was going. The assertion is that it *arrives*: a fling handed
      // nowhere leaves a `ScrollBallisticActivity` installed with nothing
      // ticking it, which answers `freeze` to every layout change for the life
      // of the panel.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      await tester.fling(find.byType(ListView), const Offset(0, -200), 800);
      await tester.pump(const Duration(milliseconds: 16));
      expect(link.model.activity, isA<ScrollBallisticActivity>());

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(physics: const ClampingScrollPhysics()),
        ),
      );
      await tester.pumpAndSettle();

      expect(link.model.activity, isA<IdlePanelActivity>());
      final heights = [for (final (_, e) in link.model.detents.snaps) e.px];
      expect(
        heights.any((h) => (h - link.model.extent.px).abs() < 0.5),
        isTrue,
        reason: 'left at ${link.model.extent.px}, detents are $heights',
      );
      // And **which** detent, because "landed on one" is satisfied by a panel
      // handed to a settle from rest. One frame in the panel is at 411, whose
      // nearest detent is `.medium` at 469.68; the throw that was already
      // running carries it to `.full`. Substituting zero for the fling's own
      // velocity is a sheet that stops halfway through the gesture the user
      // made, every time a list is rebuilt under a live fling.
      expect(
        link.model.extent.px,
        closeTo(kFullFrame, 0.5),
        reason: 'the swap dropped the speed the fling was going at',
      );
    });
  });

  // ==========================================================================
  // A position that goes away rather than being replaced. `_updatePosition`
  // detaches, absorbs and then attaches, so `detach` cannot tell "this list is
  // being rebuilt" from "this list is gone" — disposal is the seam that can, and
  // it is the one the model's gesture has to be handed back at.
  // ==========================================================================
  group('a panel taken away from a live finger', () {
    testWidgets('the rest of the gesture goes to the list, not nowhere', (
      tester,
    ) async {
      // `applyUserOffset` refuses to write the panel's share into an activity
      // the model has replaced — a spring and a hand driving one sheet at once
      // is the bug that guard exists for. What it must not also do is *drop* the
      // pixels: the content's share is the leftover after the panel took its
      // cut, so a refused panel share that is not handed on is finger travel
      // that moved nothing at all.
      //
      // `goIdle` is the case the guard's own doc does not cover — it says "a
      // panel that a spring is already moving", and a park has no spring in it.
      // Measured before the fix: 30pt of finger after the park left the panel at
      // 214 and the list at 0, and it stayed dead until the finger lifted.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      expect(link.model.extent.px, closeTo(kMediumFrame + 30, 1e-9));
      expect(list.position.pixels, 0, reason: 'the premise: the panel took it');

      link.model.goIdle(target: const Detent.height(DetentValue(180)));
      await tester.pump();
      expect(link.model.activity, isA<IdlePanelActivity>());

      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();

      expect(
        list.position.pixels,
        closeTo(30, 1e-9),
        reason: 'thirty points of finger moved neither the panel nor the list',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('a captured list that leaves the tree mid-drag', () {
    testWidgets('hands the panel back rather than freezing it', (tester) async {
      // A route popped from under a finger, a page swiped away, a `ListView`
      // rebuilt under a new `Key`. The model is holding a `ScrollDragActivity`
      // whose position is about to stop existing, and nothing ends it: measured
      // before the fix, the panel sat at 529.68 answering
      // `LayoutCorrection.freeze` and reporting `isUserDriven` for the life of
      // the app — so it could no longer follow a rotation or a keyboard,
      // `updateConfig` would never re-snap it, and a route would never begin its
      // exit.
      //
      // Both halves are asserted. "Not scroll-driven" alone is satisfied by a
      // panel that was never dragged at all, which is why the drag is measured
      // first.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(link.model.extent.px, closeTo(kMediumFrame + 60, 1e-9));
      expect(link.model.activity, isA<ScrollDragActivity>());

      await tester.pumpWidget(
        panel(model: link.model, link: link, content: const SizedBox()),
      );

      expect(link.positions, isEmpty);
      expect(
        link.model.activity,
        isNot(isA<ScrollDrivenActivity>()),
        reason:
            'the panel is holding a gesture whose position no longer exists: '
            '${link.model.activity}',
      );
      expect(
        link.model.activity.isUserDriven,
        isFalse,
        reason: 'and it still thinks a finger is on it',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(link.model.extent.px, closeTo(kMediumFrame, 0.5));
    });

    testWidgets('but a list merely rebuilt keeps its gesture', (tester) async {
      // The other side of the seam, and the reason this is in `dispose` rather
      // than in `PanelScrollController.detach`. Flutter detaches the old
      // position *before* building the one that absorbs it
      // (`scrollable.dart:617-636`), so a `detach` that ended the gesture would
      // end the drag the framework is in the middle of handing on — and a
      // physics change under a live finger would stop the panel dead. Disposal
      // is scheduled in a microtask, after `absorb` has already repointed the
      // model, so the identity test there is false exactly when something took
      // over.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(physics: const ClampingScrollPhysics()),
        ),
      );
      // The microtask the old position's disposal is scheduled in has run by
      // now, which is the whole risk this row exists to catch.
      await tester.pump();

      expect(
        link.model.activity,
        isA<ScrollDragActivity>(),
        reason:
            'the replaced position took the live gesture with it: '
            '${link.model.activity}',
      );
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(link.model.extent.px, closeTo(kMediumFrame + 100, 1e-9));

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  // ==========================================================================
  // Two lists in one panel — a `TabBarView` of them, a `PageView`, or just a
  // `Column` of two. Nothing else in this suite ever builds a second position,
  // and three of this class's six overrides carry an identity test whose whole
  // job is to tell one from the other.
  // ==========================================================================
  group('two lists in one panel', () {
    Widget twoLists() => Column(
      children: [
        SizedBox(height: 200, child: longList()),
        SizedBox(height: 200, child: longList()),
      ],
    );

    testWidgets('only the gesture the panel belongs to may move it', (
      tester,
    ) async {
      // Two fingers, one on each list. The second one to land takes the panel —
      // its `drag` installs its own `ScrollDragActivity` on the model — and
      // from that moment the first finger is arbitrating for a gesture that is
      // no longer the panel's. Without the identity test it writes into the
      // second finger's accumulator anyway, so one sheet is driven by two
      // hands at once and moves at twice the speed of either.
      //
      // **And the pixels the first finger is refused go to its own list.** They
      // used to go nowhere: the content's share is computed as the leftover
      // after the panel takes its cut, so dropping the panel's half without
      // adding it back loses the finger's motion outright, and the first list
      // stood still under a moving thumb until it was lifted. The panel is the
      // only thing a second finger can take away; the list underneath the first
      // one is still its to scroll.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: twoLists()),
      );
      final scrollables = find.byType(Scrollable);
      final firstList = tester.state<ScrollableState>(scrollables.at(0));
      expect(link.positions, hasLength(2));

      final first = await tester.startGesture(
        tester.getCenter(scrollables.at(0)),
        pointer: 11,
      );
      await first.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(link.model.extent.px, closeTo(kMediumFrame + 40, 1e-9));
      expect(
        firstList.position.pixels,
        0,
        reason:
            'the premise: while the panel was its to move, its list was not',
      );

      final second = await tester.startGesture(
        tester.getCenter(scrollables.at(1)),
        pointer: 12,
      );
      await second.moveBy(const Offset(0, -40));
      await tester.pump();
      final owned = link.model.extent.px;
      expect(owned, closeTo(kMediumFrame + 80, 1e-9));

      await first.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(
        link.model.extent.px,
        owned,
        reason: 'the first finger moved a panel that a second one is holding',
      );
      expect(
        firstList.position.pixels,
        closeTo(40, 1e-9),
        reason:
            'the refused 40pt went nowhere: the first list stood still under a '
            'thumb that had moved',
      );

      await first.up();
      await second.up();
      await tester.pumpAndSettle();
    });

    testWidgets('one list going idle does not release the other\'s gesture', (
      tester,
    ) async {
      // `goIdle` releases the panel to its own settle, which is right when the
      // list that idled is the one driving it and catastrophic when it is not:
      // a `jumpTo` on the *other* list — a tab changing, an app scrolling a
      // list to the top — would tear the panel out from under a live finger and
      // spring it to a detent, and the finger would then be arbitrating for a
      // gesture the model has already replaced.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: twoLists()),
      );
      final scrollables = find.byType(Scrollable);
      final other = tester.state<ScrollableState>(scrollables.at(1));

      final gesture = await tester.startGesture(
        tester.getCenter(scrollables.at(0)),
        pointer: 11,
      );
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(link.model.activity, isA<ScrollDragActivity>());

      other.position.jumpTo(120);
      await tester.pump();

      expect(
        link.model.activity,
        isA<ScrollDragActivity>(),
        reason: 'the other list ended a gesture that was not its to end',
      );
      expect(link.model.extent.px, closeTo(kMediumFrame + 40, 1e-9));

      // And the finger still owns it, which is the half that says the panel is
      // usable afterwards rather than merely un-settled.
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(link.model.extent.px, closeTo(kMediumFrame + 80, 1e-9));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('one list\'s release does not take the other\'s fling', (
      tester,
    ) async {
      // `goBallistic` tells a fused release from a bare scroll fling by what
      // the model is holding. With two lists that test needs the second half —
      // *whose* fling it is — or the other list builds a second
      // `FusedBallisticActivity` on the first one's panel activity, from an
      // axis measured at its own offset: two activities writing one extent,
      // and the model's clock advanced twice per frame by two tickers.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: twoLists()),
      );
      final scrollables = find.byType(Scrollable);
      final other = tester.state<ScrollableState>(scrollables.at(1));

      await tester.fling(scrollables.at(0), const Offset(0, -60), 2000);
      await tester.pump(const Duration(milliseconds: 16));
      expect(link.model.activity, isA<ScrollBallisticActivity>());

      // A `jumpTo` is the ordinary way another list reaches `goBallistic`
      // without a finger: it is `goIdle` and then `goBallistic(0)`.
      other.position.jumpTo(120);
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        other.position.toString(),
        isNot(contains('FusedBallisticActivity')),
        reason: 'the second list took over a fling belonging to the first',
      );
      await tester.pumpAndSettle();
      expect(link.model.extent.px, closeTo(kFullFrame, 0.5));
    });
  });
}
