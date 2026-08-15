import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/scroll/policy.dart';

import 'harness.dart';

// ============================================================================
// Pull to refresh: the row that argues with our own claim.
//
// DESIGN.md A6.5, in full. At the largest detent, a downward drag from a list
// already at its top has two legitimate readings: iOS says it moves the sheet
// toward its next-smaller detent (S6), and every list in every app says it
// refreshes. Both cannot win.
//
// `smooth_sheets` hands the choice to the developer behind
// `delegateUnhandledOverscrollToChild` and defaults it off, so a
// `RefreshIndicator` inside a sheet silently does nothing. That is the same
// shape as `SheetScrollConfiguration.disabled` being the default — a capability
// behind a switch the reader has to know exists — and requirement 6 forbids us
// the equivalent.
//
// So the knob is a named policy and the argument is about the **default**. This
// file tests both ends of the policy and both sides of the default, and it
// tests the *cost* of the default in the same group as the capability it buys —
// because a price recorded somewhere else is a price nobody reads until it
// surprises them.
// ============================================================================

void main() {
  // The widget group at the bottom needs the phone these constants come off:
  // on `flutter_test`'s 800x600 surface `.full` resolves to 538, so a panel
  // opened at 812 is *above* its own largest detent and "fully open" would be
  // true for a reason the test is not about.
  useIPhone17Pro();

  group('the default buys a working RefreshIndicator, and what it costs', () {
    test('fully open, at the top, a downward drag is the content\'s', () {
      // The capability. The list overscrolls, which is what a
      // `RefreshIndicator` listens for — it sees a real `OverscrollNotification`
      // because the list really did overscroll, not because anything simulated
      // one for it.
      final link = linkAt(kFullFrame);
      final split = link.split(-40, FakeContent());
      expect(split.content, -40);
      expect(split.panel, 0);
    });

    test('and so a fully open panel cannot be shrunk by dragging its list', () {
      // The price, stated where the capability is stated. The handle, the
      // background and `PanelController` still shrink it; the list no longer
      // does. Anyone who reads this as a bug should read the group name.
      //
      // Distinct from the row above only in what it asserts about the panel —
      // and it is worth a second test because the two are the two halves
      // somebody will eventually want to have both of, and they cannot.
      final link = linkAt(kFullFrame);
      expect(link.split(-40, FakeContent()).panel, 0);
      expect(link.panelMayTake(-40, FakeContent()), isFalse);
    });

    for (final (name, extent) in [
      ('the peek detent', kPeekFrame),
      ('the medium detent', 469.68),
      ('between two detents', 300.0),
    ]) {
      test('at $name the panel keeps it — S6 is untouched below the top', () {
        // "The sheet keeping the gesture everywhere else" is the other half of
        // A6.5's sentence, and it is three rows rather than one because a
        // policy that fired below the largest detent would still pass a single
        // row taken at the peek.
        final link = linkAt(extent);
        expect(link.split(-40, FakeContent()).panel, -40);
      });
    }

    test('growing is unaffected — refresh is a shrinking-direction rule', () {
      // The refresh argument is about one direction. An implementation that
      // vetoed the panel whenever it was fully open would also stop it
      // rubber-banding upward past `.full`, which is a different behaviour
      // nobody asked to change.
      final link = linkAt(kFullFrame);
      expect(link.split(30, FakeContent.short()).panel, 30);
    });
  });

  group('the ends of the policy', () {
    test('never: the panel shrinks and no refresh is reachable', () {
      // Pure S6, for a panel whose content is not a feed. A place detail or a
      // form wants a downward drag to mean "make this smaller", and a spinner
      // appearing would be the surprise.
      final link = linkAt(kFullFrame, refreshPolicy: PanelRefreshPolicy.never);
      final split = link.split(-40, FakeContent());
      expect(split.panel, -40);
      expect(split.content, 0);
    });

    test('always: the content keeps it at every detent', () {
      // The end that makes this three values rather than a boolean over the
      // default. A panel whose whole content is a refreshable feed wants the
      // refresh at every detent, and the default gives it at exactly one.
      for (final extent in [kPeekFrame, 469.68, kFullFrame]) {
        final link = linkAt(extent, refreshPolicy: PanelRefreshPolicy.always);
        final split = link.split(-40, FakeContent());
        expect(split.content, -40, reason: 'at extent $extent');
        expect(split.panel, 0, reason: 'at extent $extent');
      }
    });

    test('always still lets a scrolled list scroll first', () {
      // `always` is about who wins the *contested* gesture, not about
      // suspending the split. A list scrolled 300px still scrolls back to its
      // top under a downward drag, and only then does the argument arise.
      final link = linkAt(kFullFrame, refreshPolicy: PanelRefreshPolicy.always);
      final split = link.split(-40, FakeContent(pixels: 300));
      expect(split.content, -40);
    });
  });

  group('what "fully open" means', () {
    test('A6.5\'s two readings are the same predicate', () {
      // A6.5 asks whether "fully open" means *the largest detent* or *no larger
      // detent exists in this direction*, and says to settle it on a device.
      //
      // There is nothing to settle: with a strictly-greater `neighbourAbove`
      // the two agree at every extent. Below the largest both are false, at it
      // both are true by different routes, above it — a rubber-banded overdrag
      // — both are true. Recorded here as a finding rather than left open, and
      // asserted across the travel rather than at the one point where a
      // coincidence would be unsurprising.
      final detents = linkAt(kPeekFrame).detents;
      for (
        var extent = kPeekFrame - 50;
        extent <= kFullFrame + 50;
        extent += 7
      ) {
        expect(
          extent >= detents.max.px,
          detents.neighbourAbove(Extent(extent)) == null,
          reason: 'the two readings disagree at $extent',
        );
      }
      // And the arbiter answers what both of them say, outside the band where
      // the third reading below differs from both. Asked through `isAtCeiling`,
      // which is the predicate the veto is actually written on: there used to be
      // a wider `isFullyOpen` here, it agreed with both A6.5 readings *above*
      // the largest detent where the veto does not, and no production code read
      // it — so this row proved the equivalence about a synonym.
      expect(linkAt(kMediumFrame).isAtCeiling, isFalse);
      expect(linkAt(kFullFrame).isAtCeiling, isTrue);
    });

    test('but the third reading is the one that matters', () {
      // Neither of A6.5's options survives a spring. A settle that stopped a
      // tenth of a pixel short of `.full` is visually finished and fails both,
      // so the refresh would silently not fire on a panel the user has already
      // finished opening.
      //
      // Half a physical pixel of the display the panel is actually on is the
      // threshold, which is 0.1667 here and is what `Extent.isCloseTo` compares
      // at everywhere else in this package. The two rows either side rule out
      // both an exact comparison and a round 1pt slop.
      expect(linkAt(kFullFrame - 0.1).split(-40, FakeContent()).content, -40);
      expect(linkAt(kFullFrame - 0.5).split(-40, FakeContent()).content, 0);
    });

    test('a single-detent panel is on its ceiling at its only height', () {
      // Decided here rather than inherited. With one detent `min == max`, so the
      // panel is standing on its ceiling at the only height it has and
      // `whenFullyOpen` vetoes every shrinking delta from the content's start —
      // at every moment, for the panel's whole life.
      //
      // **Today that is the answer the default exists to give.** There is
      // nowhere to shrink to, so a veto that handed the drag to the panel would
      // only rubber-band it; handing it to the content is what makes a
      // `RefreshIndicator` work in a one-size sheet, which is the commonest
      // sheet shape there is.
      //
      // **The day `Detent.dismissed` lands it is not free**, and the answer is
      // still this one: a set of `[dismissed, full]` is on its ceiling at
      // `full`, so a fully open sheet could not be dismissed by dragging its
      // list. That is not a new cost — it is exactly the price `whenFullyOpen`
      // already charges every multi-detent panel, stated on the policy itself:
      // the handle, the background and `PanelController` still shrink it, and an
      // app whose sheet is a feed all the way down chooses
      // `PanelRefreshPolicy.never`.
      final link = linkAt(kFullFrame, detents: kSingleSet);
      expect(link.isAtCeiling, isTrue);
      expect(link.split(-40, FakeContent.short()).content, -40);
      expect(link.split(-40, FakeContent()).content, -40);

      // And it is a *policy* answer rather than a fact about a one-detent set,
      // which is the half that makes the paragraph above a decision: the same
      // set, one policy across, gives the whole drag to the panel.
      expect(
        linkAt(
          kFullFrame,
          detents: kSingleSet,
          refreshPolicy: PanelRefreshPolicy.never,
        ).split(-40, FakeContent.short()).panel,
        -40,
      );
    });

    test('and the band above the ceiling is the same half pixel wide', () {
      // The side nobody tested, and the one a spring actually produces: a
      // settle overshoots before it converges, so the panel spends real frames
      // a fraction of a pixel *above* `.full`. The rail has to be the same
      // width on both sides of the detent, or the indicator arms on the way up
      // and silently does not on the way down.
      //
      // Past half a physical pixel the panel is genuinely off its rail — held
      // up by a rubber band with somewhere for a downward drag to go — and the
      // veto is skipped so it can come back. That is the row below, and the
      // 90pt row after it is the same claim well past any tolerance.
      expect(linkAt(kFullFrame + 0.1).split(-40, FakeContent()).content, -40);
      expect(linkAt(kFullFrame + 0.5).split(-40, FakeContent()).panel, -40);
      expect(linkAt(kFullFrame + 90).split(-40, FakeContent()).panel, -40);
    });
  });

  // ==========================================================================
  // The row itself: `smooth_sheets`' `pull_to_refresh_in_sheet` tutorial, with
  // its flag deleted. If this cannot be written without reaching past the
  // public API, A6's coverage table has a "no" in it.
  // ==========================================================================
  group('an ordinary RefreshIndicator, with nothing configured', () {
    testWidgets('refreshes when the panel is fully open', (tester) async {
      var refreshed = false;
      final link = linkAt(kFullFrame);

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: RefreshIndicator(
            onRefresh: () async => refreshed = true,
            child: longList(),
          ),
        ),
      );

      // A drag and not a fling, and the difference is not about panels.
      // `WidgetTester.fling` sends fifty moves and lifts, and under the bouncing
      // physics an iOS theme installs, 300pt of finger at 1000px/s becomes about
      // 12pt of overscroll — a quarter of what `RefreshIndicator` arms at.
      // Measured against the same widget with no panel anywhere near it: the
      // fling leaves `refreshed` false there too, so a fling here would have
      // been a test of the gesture rather than of the handoff. This is the
      // gesture Flutter's own `refresh_indicator_test.dart` uses.
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();

      expect(
        refreshed,
        isTrue,
        reason:
            'nothing panel-aware in the content, no configuration object, and '
            'the indicator behaves as it does outside a panel',
      );
    });

    testWidgets('and the release does not close the panel behind it', (
      tester,
    ) async {
      // The other half of the same gesture, and the one an endpoint assertion on
      // `refreshed` cannot see. The list is overscrolled when the finger lifts —
      // it has to be, because the veto gave it every pixel of a drag it had no
      // room for — and `FusedAxis.positionOf` adds the panel's travel to the
      // content's offset, so a release seeded from a *negative* offset reads as
      // a panel 150pt shorter than the one on screen. Measured before the fix:
      // the sheet settled from 812 to 469.68 the moment the spinner appeared.
      var refreshed = false;
      final link = linkAt(kFullFrame);

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: RefreshIndicator(
            onRefresh: () async => refreshed = true,
            child: longList(),
          ),
        ),
      );

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();

      expect(refreshed, isTrue);
      expect(
        link.model.extent.px,
        kFullFrame,
        reason: 'the panel that owned none of the gesture kept none of it',
      );
    });

    testWidgets('and the panel shrinks instead at a smaller detent', (
      tester,
    ) async {
      // The same widget tree, the same gesture, one detent lower. Two
      // assertions, because "the panel moved" alone would be satisfied by an
      // implementation that shrank the panel *and* refreshed, which is the one
      // outcome both readings agree is wrong.
      var refreshed = false;
      final link = linkAt(kMediumFrame);

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: RefreshIndicator(
            onRefresh: () async => refreshed = true,
            child: longList(),
          ),
        ),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();

      expect(link.model.extent.px, lessThan(kMediumFrame));
      expect(refreshed, isFalse);

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
