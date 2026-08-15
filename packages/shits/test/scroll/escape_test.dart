import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/scroll/link.dart';
import 'package:shits/src/scroll/position.dart';

import 'harness.dart';

// ============================================================================
// What escapes, and how loudly.
//
// `capture_test.dart` measures which scrollables the framework hands us and
// which it does not. Four of them it does not, and each is a piece of code an
// average app writes without thinking: `ListView(controller: myController)`,
// `primary: false`, a bare `Scrollable`, a horizontal list.
//
// One of those four is *correct* and must be silent. The other three are
// mistakes whose symptom is that the sheet simply never moves — behaviour
// identical to a list outside a panel, with nothing anywhere saying why. That
// is the `SheetScrollConfiguration.disabled` trap this design is written
// against, and the difference has to be that ours cannot be quiet.
//
// So there are two claims here and they are equally load-bearing:
//
//   1. the three mistakes throw, once, naming the widget and both fixes;
//   2. the four correct cases — an axis mismatch, a nested inner list, a text
//      field, and a list that brought a `PanelScrollController` — say nothing.
//
// A detector that only satisfies (1) is worse than none: it complains about a
// carousel in a sheet, which is the commonest correct thing anyone will put in
// one.
// ============================================================================

/// Drags [finder] a little, and returns whatever the drag threw.
Future<Object?> dragAndCatch(WidgetTester tester, Finder finder) async {
  await tester.drag(finder, const Offset(0, -80));
  await tester.pump();
  return tester.takeException();
}

void main() {
  // Every gesture below starts at [kInsidePanel], which is 774pt down a phone
  // that is 874pt tall. On `flutter_test`'s own 800x600 surface that point is
  // off the bottom of the window and every drag in this file hits nothing —
  // which reads as "the detector stayed quiet", the exact outcome half these
  // tests are asserting.
  useIPhone17Pro();

  group('a scrollable that escaped capture complains, once', () {
    testWidgets('one that brought its own controller', (tester) async {
      final own = ScrollController();
      addTearDown(own.dispose);
      final link = linkAt(kMediumFrame);

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(controller: own),
        ),
      );

      final error = await dragAndCatch(tester, find.byType(ListView));
      expect(error, isFlutterError);
      final message = error.toString();
      // The widget, so the message points at a line of the app's code rather
      // than at a `ScrollPosition` the author never wrote.
      expect(message, contains('ListView'));
      // And **both** fixes, because there are two and an author who is given
      // only one will take the wrong one for their case: a list that genuinely
      // needs a controller cannot "just drop it".
      expect(message, contains('PanelScrollController'));
      expect(message, contains('primary'));
    });

    testWidgets('one that opted out with primary: false', (tester) async {
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(model: link.model, link: link, content: longList(primary: false)),
      );
      expect(await dragAndCatch(tester, find.byType(ListView)), isFlutterError);
    });

    testWidgets('a bare Scrollable', (tester) async {
      // The case neither `PrimaryScrollController` nor a `ScrollView`-shaped
      // detector can see, and the reason the detection channel is
      // `ScrollBehavior`: `scrollable.dart:618` reads the ambient behaviour
      // unconditionally in `didChangeDependencies`, with no `primary` gate and
      // no controller gate.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: Scrollable(
            viewportBuilder: (context, offset) => Viewport(
              offset: offset,
              slivers: [
                SliverList.builder(
                  itemCount: 60,
                  itemBuilder: (context, i) =>
                      SizedBox(height: 48, child: Text('row $i')),
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        await dragAndCatch(tester, find.byType(Scrollable)),
        isFlutterError,
      );
    });

    testWidgets('once per position, not once per delta', (tester) async {
      // This is reached from `applyPhysicsToUserOffset`, which runs on every
      // frame of a drag. An unguarded throw reports the same mistake sixty
      // times a second and buries the first stack, which is the one with the
      // gesture in it.
      final own = ScrollController();
      addTearDown(own.dispose);
      final link = linkAt(kMediumFrame);

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(controller: own),
        ),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isFlutterError);
      expect(
        tester.takeException(),
        isNull,
        reason: 'eight deltas, one mistake, one report',
      );
    });
  });

  group('and the correct cases say nothing', () {
    testWidgets('a horizontal carousel inside a vertical panel', (
      tester,
    ) async {
      // `capture_test.dart` pins that the framework does not give us this one,
      // and pins it as *wanted* behaviour. A detector without an axis check
      // complains about the commonest correct thing anyone puts in a sheet.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 40,
              itemExtent: 100,
              itemBuilder: (context, i) => Text('card $i'),
            ),
          ),
        ),
      );

      await tester.drag(find.byType(ListView), const Offset(-80, 0));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the inner list of a nested pair', (tester) async {
      // `scroll_view.dart:529-532` wraps a scroll view that inherited in
      // `PrimaryScrollController.none`, so everything below it correctly does
      // not attach. The framework suppressed it deliberately; treating that as
      // a mistake would make every tab of lists unusable.
      //
      // The predicate that tells this apart from `primary: false` is the same
      // lookup `shouldInherit` itself uses — the nearest
      // `PrimaryScrollController` ancestor, and whether its controller is
      // identically ours.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: ListView(
            children: [
              SizedBox(
                height: 200,
                child: ListView.builder(
                  itemCount: 40,
                  itemExtent: 48,
                  itemBuilder: (context, i) => Text('inner $i'),
                ),
              ),
              for (var i = 0; i < 20; i++)
                SizedBox(height: 48, child: Text('$i')),
            ],
          ),
        ),
      );

      await tester.drag(find.byType(ListView).last, const Offset(0, -60));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a text field', (tester) async {
      // The boundary DESIGN.md names as correct — typing must not resize the
      // sheet — and does not say how it is told apart. It is an `EditableText`
      // ancestor check, it is a heuristic, and it is the second place after
      // `physics:` where this channel is not exact.
      //
      // A multi-line field is the case that matters: a single-line one is a
      // horizontal scrollable and the axis check already covers it, so a
      // detector could pass a single-line row while complaining about every
      // comment box in the app.
      final link = linkAt(kFullFrame);
      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: const TextField(maxLines: 4),
        ),
      );

      await tester.enterText(find.byType(TextField), 'a\nb\nc\nd\ne\nf\ng\n');
      await tester.drag(find.byType(TextField), const Offset(0, -40));
      await tester.pump();
      expect(tester.takeException(), isNull);

      // And asked directly, because a drag on a text field is a *selection*
      // gesture: it never reaches `applyPhysicsToUserOffset`, so the silence
      // above is the gesture's and not the exemption's. This is the exemption.
      final inner = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(EditableText),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        inner.position.axis,
        Axis.vertical,
        reason:
            'a single-line field is horizontal and the axis check would '
            'have covered it, which is why this one has four lines',
      );
      expect(link.isEscape(inner.position), isFalse);
    });

    test('a bare ScrollMetrics is a snapshot and names no widget', () {
      // Reached from `applyPhysicsToUserOffset`, whose parameter is typed
      // `ScrollMetrics` — and `ScrollMetrics.copyWith` produces them by the
      // dozen. There is no element tree behind one, so the three exemptions that
      // need a `BuildContext` cannot be asked and a report against it would name
      // no line of anybody's code.
      final link = linkAt(kMediumFrame);
      expect(
        link.isEscape(
          FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 1000,
            pixels: 0,
            viewportDimension: 800,
            axisDirection: AxisDirection.down,
            devicePixelRatio: 3,
          ),
        ),
        isFalse,
      );
    });

    testWidgets('a list that brought a PanelScrollController', (tester) async {
      // The fix the error message names, working. A list that genuinely needs
      // its own controller — to jump to an index, to read an offset — keeps its
      // place in the handoff, and that is a two-word change rather than a
      // redesign.
      final link = linkAt(kMediumFrame);
      final own = PanelScrollController(link: link);
      addTearDown(own.dispose);

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(controller: own),
        ),
      );

      await tester.drag(find.byType(ListView), const Offset(0, 80));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // And it really did hand off, rather than merely staying quiet.
      expect(link.model.extent.px, lessThan(kMediumFrame));

      // Asked directly as well. `PanelScrollPhysics` returns on
      // `position is PanelScrollPosition` before it ever calls `isEscape`, so
      // the arbiter's own first row is unreachable through the drag above — and
      // an arbiter that called every one of its own positions an escape would
      // still leave this test green.
      final list = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(link.isEscape(list.position), isFalse);
    });

    testWidgets('a list that supplied its own physics', (tester) async {
      // The whole reason the split lives in `PanelScrollPosition` and not in
      // `ScrollPhysics`. `scrollable.dart:622` applies the widget's physics
      // outermost and `scroll_physics.dart:710-716` does not delegate
      // `applyPhysicsToUserOffset` to its parent, so a design that split in
      // physics is silently disabled by this one constructor argument.
      //
      // Owning the position makes it immune: this list is still ours, so the
      // detector never even looks at it.
      final link = linkAt(kMediumFrame);
      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: ListView.builder(
            physics: const BouncingScrollPhysics(),
            itemCount: 60,
            itemExtent: 48,
            itemBuilder: (context, i) => Text('row $i'),
          ),
        ),
      );

      await tester.drag(find.byType(ListView), const Offset(0, 80));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(link.model.extent.px, lessThan(kMediumFrame));
    });
  });

  // ==========================================================================
  // Two panels in one tree — a sheet presented over a sheet, or a drawer with a
  // sheet inside it. Nothing else in this suite builds a second link, and both
  // ends of the escape test carry an identity check whose only job is to say
  // *whose* panel a scrollable belongs to.
  // ==========================================================================
  group('a second panel in the tree', () {
    testWidgets('a list driving another panel is an escape from this one', (
      tester,
    ) async {
      // The first exemption reads "one of ours", and the qualifier is the whole
      // of it: a list inside this panel that was handed a `PanelScrollController`
      // belonging to a *different* one arbitrates for a sheet that is not the
      // one it is sitting in. Dragging it grows the other panel and this one
      // never moves, which is the same symptom as no capture at all — and a
      // bare type test calls it ours and says nothing.
      // The other panel is **fully open**, and that is not decoration. The
      // report lives on the physics chain, which is reached from
      // `ScrollPositionWithSingleContext.applyUserOffset` — and our own
      // `applyUserOffset` only calls `super` when the content has a share. A
      // drag the foreign panel swallows whole therefore never reaches the
      // detector at all, so a fixture that let it swallow one would assert the
      // silence rather than the report.
      final ours = linkAt(kMediumFrame);
      final other = linkAt(kFullFrame);
      addTearDown(other.dispose);
      final foreign = PanelScrollController(link: other);
      addTearDown(foreign.dispose);

      await tester.pumpWidget(
        panel(
          model: ours.model,
          link: ours,
          content: longList(controller: foreign),
        ),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      expect(
        list.position,
        isA<PanelScrollPosition>(),
        reason: 'the premise: a bare type test would call this one of ours',
      );
      expect(ours.positions, isEmpty);
      expect(other.positions, hasLength(1));
      expect(ours.isEscape(list.position), isTrue);
      // And it is not an escape from the panel it actually belongs to, so the
      // row above is about the link and not about the type.
      expect(other.isEscape(list.position), isFalse);

      // **And it is reported through the channel an app actually goes through.**
      // `PanelScrollPhysics.applyPhysicsToUserOffset` used to return on a bare
      // `position is PanelScrollPosition` before `isEscape` was ever asked,
      // which made the row above unreachable from a real drag: the two
      // assertions passed and the drag said nothing.
      expect(
        await dragAndCatch(tester, find.byType(ListView)),
        isFlutterError,
        reason: 'the list arbitrates for a sheet it is not in, silently',
      );
    });

    testWidgets('but it is reported rather than driven', (tester) async {
      // The other half of the same decision, and the one that would be worse
      // than the silence it replaces. `degradedSplit` exists because an escapee
      // has **no** arbiter; this position has one, and it is the wrong one — so
      // taking a share here would drag the sheet the list is sitting in *and*
      // the sheet its controller belongs to, from one finger, in release builds
      // only.
      PanelScrollLink.debugSuppressEscapeReports = true;
      addTearDown(() => PanelScrollLink.debugSuppressEscapeReports = false);

      final ours = linkAt(kMediumFrame);
      final other = linkAt(kFullFrame);
      addTearDown(other.dispose);
      final foreign = PanelScrollController(link: other);
      addTearDown(foreign.dispose);

      await tester.pumpWidget(
        panel(
          model: ours.model,
          link: ours,
          content: longList(controller: foreign),
        ),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        list.position.pixels,
        closeTo(60, 1e-9),
        reason:
            'the premise: the other panel arbitrated this delta and handed the '
            'list its share, which is what carries it into the detector',
      );
      expect(
        ours.model.extent.px,
        kMediumFrame,
        reason: 'and one finger moved two sheets',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a list inside another panel is not this one\'s business', (
      tester,
    ) async {
      // The other end of the same question. A list that escaped capture inside
      // a *different* panel is that panel's mistake to report; a link that
      // claimed it would throw a `FlutterError` naming a widget that is
      // nowhere in its own subtree, and — in release — would install a drag on
      // a panel the finger is nowhere near.
      final outer = linkAt(kMediumFrame);
      addTearDown(outer.dispose);
      final inner = linkAt(kMediumFrame);

      await tester.pumpWidget(
        panel(
          model: inner.model,
          link: inner,
          content: longList(primary: false),
        ),
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      expect(
        inner.isEscape(list.position),
        isTrue,
        reason: 'the premise: this really is an escape, for the panel it is in',
      );
      expect(outer.isEscape(list.position), isFalse);
    });
  });

  group('the release build degrades rather than breaking', () {
    testWidgets('an escaped list still drags the panel, and settles', (
      tester,
    ) async {
      // DESIGN.md A4's rule: the release behaviour must be reachable by a test
      // rather than hidden behind `coverage:ignore`. In debug the report throws
      // before this path runs, so the hatch is what makes it reachable — the
      // same shape `RenderObject.debugCheckingIntrinsics` establishes for
      // exactly this.
      //
      // "Degraded" means the panel is dragged and then settles at zero
      // velocity: there is no fling handoff, because the escapee's
      // `goBallistic` is its own, and no `absorb`, because we never owned it.
      PanelScrollLink.debugSuppressEscapeReports = true;
      addTearDown(() => PanelScrollLink.debugSuppressEscapeReports = false);

      final own = ScrollController();
      addTearDown(own.dispose);
      final link = linkAt(kMediumFrame);

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(controller: own),
        ),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        link.model.extent.px,
        greaterThan(kMediumFrame),
        reason: 'the drag-time split still runs when the report is suppressed',
      );
      // And what is handed back to the escapee is **its** share, not the
      // panel's. Getting that wrong is the one bug in this path a user would
      // describe rather than report: one finger, and the list scrolls by the
      // same 60pt the sheet just grew by — double motion from a single drag,
      // in release builds only, where nothing throws to say why.
      expect(
        own.position.pixels,
        0,
        reason:
            'the panel took all 60, so there is nothing left for the list, '
            'and it moved ${own.position.pixels} anyway',
      );

      await gesture.up();
      await tester.pumpAndSettle();

      // The drag's end is observed rather than received — the escapee's
      // `isScrollingNotifier` is the only signal there is — and without that
      // the panel would keep a drag activity installed for the life of the app,
      // freezing every later layout change.
      final heights = [for (final (_, e) in link.model.detents.snaps) e.px];
      expect(
        heights.any((h) => (h - link.model.extent.px).abs() < 0.5),
        isTrue,
        reason: 'left at ${link.model.extent.px}, detents are $heights',
      );
    });

    testWidgets('and an escapee that leaves the tree mid-drag ends too', (
      tester,
    ) async {
      // The one end `isScrollingNotifier` cannot report.
      // `ScrollPosition.dispose` disposes the notifier
      // (`scroll_position.dart:1113-1117`) **without ever setting it false**,
      // and the release the escapee does get on the way out — the gesture
      // recogniser's own disposal arriving as `Drag.end`
      // (`monodrag.dart:753-765`) — leaves it holding a ballistic, so the last
      // value the notifier ever carries is `true`.
      //
      // Measured with the observation alone: the panel sat at 529.68 holding a
      // `ScrollDragActivity`, `isUserDriven` and answering
      // `LayoutCorrection.freeze`, through `pumpAndSettle` and for the rest of
      // the session — so it could no longer follow a rotation or a keyboard and
      // a route would never begin its exit. It is the same hole
      // `PanelScrollPosition.dispose` closes for a captured list, from the side
      // where the position is not ours to override.
      PanelScrollLink.debugSuppressEscapeReports = true;
      addTearDown(() => PanelScrollLink.debugSuppressEscapeReports = false);

      final own = ScrollController();
      addTearDown(own.dispose);
      final link = linkAt(kMediumFrame);

      await tester.pumpWidget(
        panel(
          model: link.model,
          link: link,
          content: longList(controller: own),
        ),
      );

      final gesture = await tester.startGesture(kInsidePanel);
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(link.model.extent.px, closeTo(kMediumFrame + 60, 1e-9));
      expect(link.model.activity, isA<ScrollDragActivity>());

      await tester.pumpWidget(
        panel(model: link.model, link: link, content: const SizedBox()),
      );

      expect(
        link.model.activity,
        isNot(isA<ScrollDrivenActivity>()),
        reason:
            'the panel is holding a gesture whose scrollable is gone: '
            '${link.model.activity}',
      );
      expect(link.model.activity.isUserDriven, isFalse);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(link.model.extent.px, closeTo(kMediumFrame, 0.5));
    });
  });

  testWidgets('disposing the link ends the panel\'s side of a live drag', (
    tester,
  ) async {
    // The other half of `dispose`, and the state it prevents is the one
    // `ScrollBallisticActivity.tick` names: a scroll-driven activity with
    // nothing left to drive it answers `LayoutCorrection.freeze` to every layout
    // change afterwards, so the panel can no longer follow a rotation or a
    // keyboard and sits at a height that need not be any of its detents.
    //
    // A panel widget going away while a finger is still down is the ordinary way
    // to reach it — a route popped from under a gesture.
    final link = linkAt(kMediumFrame);
    await tester.pumpWidget(
      panel(model: link.model, link: link, content: longList()),
    );

    final gesture = await tester.startGesture(kInsidePanel);
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(link.model.activity, isA<ScrollDragActivity>());

    link.dispose();
    expect(link.positions, isEmpty);
    expect(
      link.model.activity,
      isNot(isA<ScrollDrivenActivity>()),
      reason: 'the panel is its own again, and something can still move it',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  test('disposing the link forgets every position it was holding', () {
    // A link that outlived its controller and kept the positions would report
    // an escape against a disposed one — and `absorb` compares against this
    // registry, so a stale entry is a use-after-free with a lookup in front of
    // it.
    final link = linkAt(kMediumFrame);
    link.dispose();
    expect(link.positions, isEmpty);
  });

  test('there is no flag to turn the handoff on', () {
    // A source-level guard, in the shape `projection_test.dart` already uses
    // for `0.322`. DESIGN.md's requirement 6 forbids us a
    // `SheetScrollConfiguration.disabled` and forbids
    // `delegateUnhandledOverscrollToChild` by name; both are booleans that
    // gate a capability, and both are the reason a `RefreshIndicator` in a
    // sheet silently does nothing until someone reads the tutorial.
    //
    // The scroll layer has three named policies and one debug hatch, and every
    // one of them is a named type or is prefixed `debug`. Any other boolean
    // field here is a switch someone will have to discover.
    final offenders = <String>[];
    for (final entity in Directory(
      'lib/src/scroll',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final line in entity.readAsLinesSync()) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('bool ') &&
            !trimmed.startsWith('final bool ') &&
            !trimmed.startsWith('static bool ')) {
          continue;
        }
        // A method or a getter is a derived answer, not a switch; a field
        // declaration has no parameter list and no `get`.
        if (trimmed.contains('(') || trimmed.contains('get ')) continue;
        // A `debug`-prefixed hatch announces itself as one, and DESIGN.md A4
        // requires the release path to be reachable by a test.
        if (trimmed.contains('debug')) continue;
        offenders.add('${entity.path}: $trimmed');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a bool field in the scroll layer is a capability behind a switch the '
          'reader has to know exists. Unsettled choices are named policies with '
          'both ends tested — see policy.dart.',
    );
  });
}
