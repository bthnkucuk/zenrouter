import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/scroll/behavior.dart';
import 'package:shits/src/scroll/position.dart';

import 'harness.dart';

// ============================================================================
// The wiring: `PanelScrollAttachment` and the `ScrollBehavior` it installs.
//
// `capture_test.dart` next door measures the **framework's** behaviour — that a
// `PrimaryScrollController` published with `automaticallyInheritForPlatforms:
// TargetPlatform.values.toSet()` is picked up by a bare `ListView` everywhere,
// and that the framework's own default silently is not. It imports nothing from
// this package and cannot fail on anything this package does.
//
// This file is the same claim about **our** code: the widget an app actually
// writes, with a real gesture on the other end of it, on every platform the
// enum has. Every other `testWidgets` in this suite runs `TargetPlatform.iOS`,
// which is a touch platform and is therefore inside the framework's default —
// so reducing the argument in `attachment.dart` to `{TargetPlatform.iOS}` used
// to change nothing anywhere, while shipping a package whose whole handoff did
// nothing on macOS, Windows, Linux and desktop web. That is the exact
// `smooth_sheets` hole this package exists to close, and it was untested.
// ============================================================================

void main() {
  useIPhone17Pro();

  group('a bare list is captured and arbitrated on every platform', () {
    for (final platform in TargetPlatform.values) {
      testWidgets('$platform', (tester) async {
        // The platform the app configured has to survive the wrapping as well,
        // because `PanelScrollBehavior` replaces the *detector* and nothing
        // else: a behaviour that answered with its own platform would give
        // every list in the panel the wrong physics, the wrong scrollbar and
        // the wrong keyboard-dismiss behaviour, three screens away from
        // anything panel-shaped.
        late TargetPlatform reported;
        final link = linkAt(kMediumFrame);
        await tester.pumpWidget(
          panel(
            model: link.model,
            link: link,
            platform: platform,
            content: Builder(
              builder: (context) {
                reported = ScrollConfiguration.of(context).getPlatform(context);
                return longList();
              },
            ),
          ),
        );

        expect(reported, platform, reason: 'the app\'s platform was replaced');

        final list = tester.state<ScrollableState>(find.byType(Scrollable));
        expect(
          list.position,
          isA<PanelScrollPosition>(),
          reason:
              'the list did not inherit the panel\'s controller on $platform, '
              'so nothing it does can reach the panel',
        );

        // And it arbitrates, rather than merely being attached. 60pt up from a
        // list at its top, below the largest detent, is S1: the panel's whole
        // share and none of the list's.
        final gesture = await tester.startGesture(kInsidePanel);
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(link.model.extent.px, closeTo(kMediumFrame + 60, 1e-9));
        expect(
          list.position.pixels,
          0,
          reason: 'the panel had room, so the list is not what moved',
        );

        await gesture.up();
        await tester.pumpAndSettle();
      });
    }
  });

  group('the clock a self-driven motion runs on', () {
    testWidgets('is advanced by the frame delta, not by the total elapsed', (
      tester,
    ) async {
      // DESIGN.md gives this ticker to `lib/src/widgets/panel.dart`, which does
      // not exist, so the attachment holds it — and it is the *only* thing that
      // moves a panel nobody is touching. Advancing the model by `elapsed`
      // instead of by `elapsed - _elapsed` makes its clock grow quadratically:
      // after n frames of 16ms it reads 8·n·(n+1) ms rather than 16·n, so a
      // 480ms settle finishes on frame 8 instead of frame 30 and every
      // programmatic sheet motion in the app runs about four times too fast.
      //
      // `fused_ballistic_test.dart:476` pins exactly this for the *fused*
      // clock, through the re-snap window. This is the same bug in the other
      // ticker, and it is measured as elapsed frames because that is what the
      // user sees.
      final link = linkAt(kPeekFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      link.model.settleTo(
        Detent.full,
        within: const Duration(milliseconds: 480),
      );
      expect(link.model.activity, isA<SettlingPanelActivity>());

      var frames = 0;
      while (link.model.isTicking && frames < 200) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
      }

      expect(
        frames,
        greaterThan(20),
        reason:
            'a 480ms settle is 30 frames of 16ms; a clock fed the total '
            'elapsed finishes it in 8',
      );
      expect(
        frames,
        lessThan(60),
        reason: 'and it does finish, rather than never reaching its detent',
      );
      expect(link.model.extent.px, closeTo(kFullFrame, 0.5));
      await tester.pumpAndSettle();
    });
  });

  group('a link swapped under the attachment', () {
    testWidgets('moves the list onto the panel it is now in', (tester) async {
      // `didUpdateWidget` recreates the controller, because a controller's
      // positions hold the link they were created with and there is no way to
      // repoint them that is not `absorb`. Without the recreation the subtree
      // keeps publishing the *old* panel's controller, so the list stays
      // attached to a panel that is no longer on screen — and the registry the
      // escape detector and `absorb` both compare against still names it.
      final a = linkAt(kMediumFrame);
      final b = linkAt(kPeekFrame);
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await tester.pumpWidget(
        panel(model: a.model, link: a, content: longList()),
      );
      expect(a.positions, hasLength(1));

      await tester.pumpWidget(
        panel(model: b.model, link: b, content: longList()),
      );

      expect(
        a.positions,
        isEmpty,
        reason: 'the controller that held it was replaced and disposed',
      );
      expect(
        b.positions,
        hasLength(1),
        reason: 'and the list belongs to the panel it is now inside',
      );
      // **And the position's own `link` field followed**, which is the half this
      // test used to decline to assert. A controller swap does not replace the
      // position — `scrollable.dart:686-698` keeps it when the physics and the
      // controller `runtimeType` are unchanged — so `absorb` never runs, and a
      // binding repointed only there would leave the registry and the position
      // disagreeing about which panel this list belongs to. It is refreshed in
      // `PanelScrollController.attach` instead, which is the one call
      // `didUpdateWidget` does make (`scrollable.dart:711-724`).
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position, isA<PanelScrollPosition>());
      expect(
        (position as PanelScrollPosition).link,
        same(b),
        reason: 'the list is registered with b and still arbitrating for a',
      );

      // Measured through the behaviour as well, because a field comparison
      // alone is satisfied by a field nothing reads: the finger has to move the
      // sheet that is on screen. Before this, it moved the discarded one — 60pt
      // of drag grew `a` to 529.68 while `b` sat at its peek and never acquired
      // an activity at all.
      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();

      expect(b.model.extent.px, closeTo(kPeekFrame + 60, 1e-9));
      expect(
        a.model.extent.px,
        kMediumFrame,
        reason: 'the panel that is no longer on screen was dragged',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('and the panel it left is not still holding the finger', (
      tester,
    ) async {
      // The compound shape, and the only one in which the *old* link is still
      // reachable from a position that has stopped being its. A list moving
      // between panels with a finger already down, in a frame that also changes
      // the physics — so `Scrollable.didUpdateWidget` detaches and attaches the
      // position (`scrollable.dart:711-724`) **and then** replaces it
      // (`:727-729`).
      //
      // The order is what makes it a hole: the attach happens first, so by the
      // time `absorb` and `PanelScrollPosition.dispose` run, the position's link
      // is already `b` and neither of them can see the `ScrollDragActivity`
      // still installed on `a`. Measured without the release in `attach`: panel
      // `a` sat at 529.68 holding that drag, answering `LayoutCorrection.freeze`
      // and reporting `isUserDriven`, through the release and through
      // `pumpAndSettle` — so it could never follow a rotation, never be
      // re-snapped by `updateConfig`, and never begin a route exit.
      final a = linkAt(kMediumFrame);
      final b = linkAt(kMediumFrame);
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await tester.pumpWidget(
        panel(model: a.model, link: a, content: longList()),
      );
      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(a.model.activity, isA<ScrollDragActivity>());
      expect(a.model.extent.px, closeTo(kMediumFrame + 60, 1e-9));

      await tester.pumpWidget(
        panel(
          model: b.model,
          link: b,
          content: longList(physics: const ClampingScrollPhysics()),
        ),
      );

      expect(
        a.model.activity,
        isNot(isA<ScrollDrivenActivity>()),
        reason:
            'the panel the list left is still holding its gesture: '
            '${a.model.activity}',
      );
      expect(
        a.model.activity.isUserDriven,
        isFalse,
        reason: 'and still thinks a finger is on it',
      );
      expect(
        b.model.activity,
        isA<IdlePanelActivity>(),
        reason:
            'and the panel it arrived at did not inherit a gesture it never '
            'started',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('installing the behaviour costs no position churn', () {
    testWidgets('an ordinary rebuild keeps the same ScrollPosition', (
      tester,
    ) async {
      // `scroll_configuration.dart:415-418` rebuilds every scrollable under a
      // `ScrollConfiguration` whose behaviour says it changed, and
      // `ScrollableState.didChangeDependencies` recreates the `ScrollPosition`
      // outright when it does. A `shouldNotify` that answered true
      // unconditionally would therefore throw away and rebuild every position
      // in the panel on every frame of a drag — which is the exact cost owning
      // the position was supposed to avoid, and it is invisible from every
      // behavioural assertion in this suite because `absorb` puts the state
      // back.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );
      final before = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList()),
      );

      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position,
        same(before),
        reason: 'the panel rebuilt and the list was recreated with it',
      );
      expect(link.positions, hasLength(1));
    });

    test('and the physics keeps both the link and the app\'s own chain', () {
      // `ScrollPhysics.applyTo` is how the chain is rebuilt every time
      // something is composed onto it, and a field dropped there is the
      // commonest way a custom physics stops working the moment someone adds
      // `physics:` above it. Two things must survive: the link, or the detector
      // stops detecting; and the ancestor, or the app's chosen bouncing or
      // clamping feel is removed from every list in the panel.
      final link = linkAt(kMediumFrame);
      addTearDown(link.dispose);
      final physics = PanelScrollPhysics(
        link: link,
        parent: const ClampingScrollPhysics(),
      );

      final applied = physics.applyTo(const BouncingScrollPhysics());

      expect(applied.link, same(link));
      expect(
        applied.parent,
        isA<ClampingScrollPhysics>(),
        reason: 'the physics this one was built over',
      );
      expect(
        applied.parent?.parent,
        isA<BouncingScrollPhysics>(),
        reason: 'and the one it was applied to, underneath it',
      );
    });
  });
}
