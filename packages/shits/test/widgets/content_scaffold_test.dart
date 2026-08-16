import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/shits.dart';

import '../fixtures/devices.dart';
import 'harness.dart';

// ============================================================================
// DESIGN.md A6.4 is a requirement about this widget, and it settles three
// things rather than leaving them to be guessed: a panel needs a content
// scaffold, the bar is a slot on it, and its visibility is a **three**-variant
// policy — so by A5 all three are named types and all three are tested at both
// ends.
//
// The awkward part, stated rather than worked around: `natural` and `always`
// differ by two quantities, and one of them — how much of the panel has left
// the viewport — is `EdgeOffset`, which this slice pins at zero. So a live
// panel with no keyboard up cannot tell them apart, and a file that only pumped
// panels would be testing one variant twice. The keyboard is the other
// quantity, it is live now, and it is what the widget rows below use; the
// `EdgeOffset` end is driven through the pure functions, over a `PanelMetrics`
// built by hand.
//
// The panel is at `.medium` throughout — frame 469.68 in an 874pt viewport, so
// its top edge is at 404.32 — because the three numbers a wrong implementation
// would produce there (812 for the full frame, 435.68 for the detent value, 874
// for the viewport) are nowhere near it.
// ============================================================================

/// The panel's top edge at `.medium` on the 17 Pro.
final double _frameTop = kIPhone17Pro.size.height - kMediumFrame;

/// The viewport's bottom edge, which is also the panel's.
const double _frameBottom = 874;

/// The bar's height in every row below. Not 50 and not 100: it has to be small
/// enough to fit inside the peek frame and large enough that an implementation
/// which forgot it entirely misses by more than a rounding.
const double _barHeight = 60;

Widget _sheet({
  BottomBarVisibility visibility = const BottomBarVisibility.natural(),
  bool extendBodyBehindBottomBar = false,
  bool avoidsKeyboard = true,
  Detent initialDetent = Detent.medium,
  EdgeInsets viewInsets = EdgeInsets.zero,
  Widget? body,
  Widget? bottomBar = const SizedBox(
    key: Key('bar'),
    height: _barHeight,
    width: double.infinity,
  ),
  PanelController? controller,
}) => onIPhone17Pro(
  viewInsets: viewInsets,
  Panel(
    detents: kPeekSet,
    initialDetent: initialDetent,
    controller: controller,
    child: PanelContentScaffold(
      bottomBarVisibility: visibility,
      extendBodyBehindBottomBar: extendBodyBehindBottomBar,
      avoidsKeyboard: avoidsKeyboard,
      bottomBar: bottomBar,
      body: body ?? const SizedBox.expand(key: Key('body')),
    ),
  ),
);

Rect _rectOf(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(Key(key)));

void main() {
  useIPhone17Pro();

  group('the bar is pinned to the panel, not to the content', () {
    testWidgets('whatever the body is doing', (tester) async {
      // The sentence a `Column` cannot express. A body 10pt tall would leave a
      // column-placed bar floating 400pt above the sheet's edge, and a body
      // taller than the panel would push it off the bottom — and both are
      // ordinary content.
      for (final bodyHeight in <double>[10, 900]) {
        await tester.pumpWidget(
          _sheet(
            body: SizedBox(key: const Key('body'), height: bodyHeight),
            extendBodyBehindBottomBar: true,
          ),
        );

        expect(
          _rectOf(tester, 'bar'),
          Rect.fromLTRB(
            0,
            _frameBottom - _barHeight,
            kIPhone17Pro.size.width,
            _frameBottom,
          ),
          reason: 'a $bodyHeight pt body moved the bar',
        );
      }
    });

    testWidgets('and the body stops above it unless told not to', (
      tester,
    ) async {
      await tester.pumpWidget(_sheet());
      expect(
        _rectOf(tester, 'body').bottom,
        closeTo(_frameBottom - _barHeight, 1e-9),
      );
      expect(_rectOf(tester, 'body').top, closeTo(_frameTop, 1e-9));

      await tester.pumpWidget(_sheet(extendBodyBehindBottomBar: true));
      expect(_rectOf(tester, 'body').bottom, closeTo(_frameBottom, 1e-9));
      expect(_rectOf(tester, 'body').top, closeTo(_frameTop, 1e-9));
    });

    testWidgets('and is told about it through its own padding', (tester) async {
      // `Scaffold`'s bargain: a body extended behind a bar is handed the overlap
      // as `MediaQuery.padding`, so a list inside it can scroll under a
      // translucent bar and still end clear of it. Without this,
      // `extendBodyBehindBottomBar` is just an overlap and every content has to
      // measure the bar itself.
      late EdgeInsets bodyPadding;
      await tester.pumpWidget(
        _sheet(
          extendBodyBehindBottomBar: true,
          body: Builder(
            key: const Key('body'),
            builder: (context) {
              bodyPadding = MediaQuery.paddingOf(context);
              return const SizedBox.expand();
            },
          ),
        ),
      );

      expect(bodyPadding.bottom, closeTo(_barHeight, 1e-9));
    });
  });

  group('the three visibility variants', () {
    test('natural rides the panel\'s edge and nothing lifts it', () {
      // Zero for every state, including the two that lift `always`. This is the
      // variant that adds nothing, and asserting it over a state where the other
      // one is non-zero is what makes that a claim rather than a coincidence.
      const natural = BottomBarVisibility.natural();
      expect(natural.liftIn(metricsAt(extent: kMediumFrame)), 0);
      expect(
        natural.liftIn(metricsAt(extent: kMediumFrame, edgeOffset: 90)),
        0,
      );
      expect(
        natural.liftIn(metricsAt(extent: kMediumFrame, viewInsets: kKeyboard)),
        0,
      );
      expect(natural.isVisibleIn(metricsAt(extent: kPeekFrame)), isTrue);
    });

    test('always lifts over both things that separate it from the edge', () {
      // The part of the panel that has left the viewport, and whatever the
      // system has drawn over that edge. Two summands, tested apart and
      // together, because an implementation that read only one of them is right
      // on two rows out of four — and in this slice the `edgeOffset` row is the
      // one no live panel can produce.
      const always = BottomBarVisibility.always();
      expect(always.liftIn(metricsAt(extent: kMediumFrame)), 0);
      expect(
        always.liftIn(metricsAt(extent: kMediumFrame, edgeOffset: 90)),
        closeTo(90, 1e-9),
      );
      expect(
        always.liftIn(metricsAt(extent: kMediumFrame, viewInsets: kKeyboard)),
        closeTo(336, 1e-9),
      );
      expect(
        always.liftIn(
          metricsAt(
            extent: kMediumFrame,
            edgeOffset: 90,
            viewInsets: kKeyboard,
          ),
        ),
        closeTo(426, 1e-9),
      );
    });

    test('and never past the panel it belongs to', () {
      // A 336pt keyboard over a 214pt peek. The bar belongs to the panel, so the
      // lift saturates at the panel's own span; without the clamp the bar is
      // placed 122pt above a sheet it is supposed to be inside.
      expect(
        const BottomBarVisibility.always().liftIn(
          metricsAt(extent: kPeekFrame, viewInsets: kKeyboard),
        ),
        closeTo(kPeekFrame, 1e-9),
      );
    });

    test('conditional is always\'s position and the predicate\'s answer', () {
      final visibility = BottomBarVisibility.conditional(
        isVisible: (metrics) => metrics.openProgress >= 0.5,
        identity: 'half open',
      );

      expect(
        visibility.liftIn(
          metricsAt(extent: kMediumFrame, viewInsets: kKeyboard),
        ),
        closeTo(336, 1e-9),
        reason: 'a conditional bar that is showing is an always bar',
      );
      // 469.68 is 0.4276 of the travel and 812 is 1.0, so the predicate flips
      // between the middle stop and the largest — which is A6.4's own example,
      // "visible once at least half the sheet is".
      expect(visibility.isVisibleIn(metricsAt(extent: kMediumFrame)), isFalse);
      expect(visibility.isVisibleIn(metricsAt(extent: kFullFrame)), isTrue);
    });

    test('and the payload-free two are values rather than instances', () {
      // `==` and `hashCode`, and the pair rather than either alone: two
      // payload-free variants that compared unequal but hashed the same would
      // collide in any `Set` or `Map` a caller put them in, and a `hashCode`
      // nothing calls is a `hashCode` nobody has checked.
      const natural = BottomBarVisibility.natural();
      const always = BottomBarVisibility.always();

      expect(natural, isNot(always));
      expect(
        natural.hashCode,
        isNot(always.hashCode),
        reason: 'the two variants hash to one bucket',
      );
      expect(natural.hashCode, const NaturalBottomBar().hashCode);
      expect(always.hashCode, const AlwaysBottomBar().hashCode);
    });

    test('and two conditionals are the same one when their identity is', () {
      // `CustomDetent.identity`'s bargain, for `CustomDetent.identity`'s reason:
      // a closure is a fresh object every build, so a visibility compared
      // through its predicate is a different policy on every frame — and the
      // scaffold's delegate and the hide animation both compare.
      final a = BottomBarVisibility.conditional(
        isVisible: (metrics) => true,
        identity: 'half open',
      );
      final b = BottomBarVisibility.conditional(
        isVisible: (metrics) => false,
        identity: 'half open',
      );
      final c = BottomBarVisibility.conditional(
        isVisible: (metrics) => true,
        identity: 'fully open',
      );

      expect(a, b);
      expect(a, isNot(c));
      expect(a.hashCode, b.hashCode);
    });
  });

  group('the keyboard, which is what separates the two variants today', () {
    testWidgets('natural leaves the bar on the panel\'s edge, behind it', (
      tester,
    ) async {
      await tester.pumpWidget(_sheet(viewInsets: kKeyboard));

      expect(_rectOf(tester, 'bar').bottom, closeTo(_frameBottom, 1e-9));
      // And the body still clears the keyboard, because that is a different
      // knob: `avoidsKeyboard` insets the body whatever the bar is doing.
      expect(
        _rectOf(tester, 'body').bottom,
        closeTo(_frameBottom - 336, 1e-9),
        reason: 'max(bar 60, keyboard 336) is 336',
      );
    });

    testWidgets('always lifts it clear, and the body clears the bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _sheet(
          visibility: const BottomBarVisibility.always(),
          viewInsets: kKeyboard,
        ),
      );

      expect(_rectOf(tester, 'bar').bottom, closeTo(_frameBottom - 336, 1e-9));
      // max(bar 60 + lift 336, keyboard 336) = 396, which puts the body's
      // bottom exactly on the bar's top. The two rules meet rather than
      // double-counting the one obstruction.
      expect(_rectOf(tester, 'body').bottom, closeTo(_frameBottom - 396, 1e-9));
      expect(
        _rectOf(tester, 'body').bottom,
        closeTo(_rectOf(tester, 'bar').top, 1e-9),
      );
    });

    testWidgets('and one arriving under a live bar lifts it, without a build', (
      tester,
    ) async {
      // The path nothing else in this file exercises. Every other keyboard row
      // has the keyboard up from the first pump, where the bar is placed
      // correctly by the *first* layout and proves nothing about updating.
      //
      // A keyboard that arrives moves no detent — that is KB6, and it is what
      // makes this hard: the panel's extent is unchanged, so the constraints
      // the scaffold is laid out under are unchanged, so nothing relayouts it
      // by the ordinary route. Only the panel's own notification does, and it
      // arrives from inside a layout pass and is therefore delivered at the end
      // of that frame — which is what the second pump is.
      final body = Counter();
      final content = counting(
        body,
        (context) => const SizedBox.expand(key: Key('body')),
      );
      Widget build(EdgeInsets viewInsets) => _sheet(
        visibility: const BottomBarVisibility.always(),
        viewInsets: viewInsets,
        body: content,
      );

      await tester.pumpWidget(build(EdgeInsets.zero));
      expect(_rectOf(tester, 'bar').bottom, closeTo(_frameBottom, 1e-9));
      final before = body.value;

      await tester.pumpWidget(build(kKeyboard));
      await tester.pump();

      expect(
        _rectOf(tester, 'bar').bottom,
        closeTo(_frameBottom - 336, 1e-9),
        reason: 'the keyboard came up and the bar stayed behind it',
      );
      expect(
        body.value,
        before,
        reason:
            'the bar moved by rebuilding the content, which is the cost the '
            'layout delegate exists to avoid',
      );
    });

    testWidgets('and a scaffold with no bar is a body and a keyboard', (
      tester,
    ) async {
      // The null slot, which is the shape half the ported examples have. The
      // body takes the whole frame less the keyboard, and `avoidsKeyboard`
      // keeps working — it is a different knob from the bar, and an
      // implementation that reached the keyboard through the bar's own band
      // would inset by nothing here.
      await tester.pumpWidget(_sheet(bottomBar: null));

      expect(find.byKey(const Key('bar')), findsNothing);
      expect(_rectOf(tester, 'body').top, closeTo(_frameTop, 1e-9));
      expect(_rectOf(tester, 'body').bottom, closeTo(_frameBottom, 1e-9));

      await tester.pumpWidget(_sheet(bottomBar: null, viewInsets: kKeyboard));
      // The second frame, for the reason the row above this one gives: a
      // keyboard moves no detent, so the scaffold's constraints do not change
      // and only the panel's own notification relayouts it — and that
      // notification is raised from inside a layout pass, so it is delivered at
      // the end of the frame that raised it.
      await tester.pump();

      expect(_rectOf(tester, 'body').bottom, closeTo(_frameBottom - 336, 1e-9));
    });

    testWidgets('and avoidsKeyboard: false is the other end of the policy', (
      tester,
    ) async {
      // A5: a default nobody has tried the other side of is a hardcoded choice
      // with extra steps. This is the panel whose body draws its own keyboard
      // accessory.
      await tester.pumpWidget(
        _sheet(viewInsets: kKeyboard, avoidsKeyboard: false),
      );

      expect(
        _rectOf(tester, 'body').bottom,
        closeTo(_frameBottom - _barHeight, 1e-9),
      );
    });
  });

  group('a conditional bar, live', () {
    testWidgets('is re-evaluated on every metrics change', (tester) async {
      // A6.4's words: "re-evaluated *whenever the metrics change*". A predicate
      // consulted only at rest would be right at both ends of every settle and
      // wrong throughout it, which is the failure a still screenshot cannot see.
      final seen = <double>[];
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _sheet(
          controller: controller,
          extendBodyBehindBottomBar: true,
          visibility: BottomBarVisibility.conditional(
            isVisible: (metrics) {
              seen.add(metrics.extent.px);
              return metrics.openProgress >= 0.5;
            },
            identity: 'half open',
          ),
        ),
      );

      seen.clear();
      controller.animateTo(Detent.full);
      // At a frame, and not at `pumpAndSettle`'s 100ms default: a 500ms spring
      // settles in ~550ms, so the default step is 7 pumps and the bounds below
      // count frames. See `scope_test.dart`'s "changes on every frame of a
      // settle, not twice", which is the same measurement one layer down.
      await tester.pumpAndSettle(const Duration(milliseconds: 16));

      expect(seen.length, greaterThan(10));
      expect(seen.toSet().length, greaterThan(10));
      expect(seen.last, closeTo(kFullFrame, 0.5));
    });

    testWidgets('and slides fully out of the frame when it says no', (
      tester,
    ) async {
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _sheet(
          controller: controller,
          extendBodyBehindBottomBar: true,
          visibility: BottomBarVisibility.conditional(
            isVisible: (metrics) => metrics.openProgress >= 0.5,
            identity: 'half open',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 0.4276 of the travel: hidden, and *fully* hidden — one bar height
      // outside the panel's own edge rather than merely lowered by whatever it
      // had been lifted over.
      expect(
        _rectOf(tester, 'bar').top,
        greaterThanOrEqualTo(_frameBottom - 0.5),
      );

      controller.animateTo(Detent.full);
      await tester.pumpAndSettle();

      expect(_rectOf(tester, 'bar').bottom, closeTo(_frameBottom, 0.5));
    });

    testWidgets('and slides back out when the predicate changes its mind', (
      tester,
    ) async {
      // The other direction, and nothing above takes it: the row before this
      // one *starts* hidden, from the animation's seed rather than from an
      // animation, and then opens. A bar that could only ever be told to
      // appear passes every assertion in this group.
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _sheet(
          controller: controller,
          initialDetent: Detent.full,
          extendBodyBehindBottomBar: true,
          visibility: BottomBarVisibility.conditional(
            isVisible: (metrics) => metrics.openProgress >= 0.5,
            identity: 'half open',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_rectOf(tester, 'bar').bottom, closeTo(_frameBottom, 0.5));

      controller.animateTo(const Detent.height(DetentValue(180)));
      await tester.pumpAndSettle();

      expect(
        _rectOf(tester, 'bar').top,
        greaterThanOrEqualTo(_frameBottom - 0.5),
        reason: 'the panel shrank past half and the bar stayed',
      );
    });

    testWidgets('and a controller swapped under it keeps the bar following', (
      tester,
    ) async {
      // The scaffold reads its handle from `PanelScope.of`, so an app that
      // swaps the panel's controller swaps both the thing the predicate
      // listens to and the thing the delegate relayouts on. One that kept the
      // old handle keeps a bar that never moves again — the controller it is
      // still listening to is detached, and a detached controller never
      // notifies.
      final first = PanelController();
      final second = PanelController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      Widget build(PanelController controller) => _sheet(
        controller: controller,
        extendBodyBehindBottomBar: true,
        visibility: BottomBarVisibility.conditional(
          isVisible: (metrics) => metrics.openProgress >= 0.5,
          identity: 'half open',
        ),
      );

      await tester.pumpWidget(build(first));
      await tester.pumpAndSettle();
      expect(
        _rectOf(tester, 'bar').top,
        greaterThanOrEqualTo(_frameBottom - 0.5),
        reason: '.medium is 0.4276 of the travel, so the bar starts away',
      );

      await tester.pumpWidget(build(second));
      second.animateTo(Detent.full);
      await tester.pumpAndSettle();

      expect(
        _rectOf(tester, 'bar').bottom,
        closeTo(_frameBottom, 0.5),
        reason: 'the bar is still waiting on a handle the panel gave up',
      );
    });

    testWidgets('and refuses to be used without extendBodyBehindBottomBar', (
      tester,
    ) async {
      // Inherited from the package this row is ported from, with its reason: a
      // bar that can leave has no fixed band to inset the body by, and a body
      // that resized as the bar slid out would relayout its whole subtree for
      // every frame of a 150ms animation.
      await tester.pumpWidget(
        _sheet(
          visibility: BottomBarVisibility.conditional(
            isVisible: (metrics) => true,
            identity: 'always true',
          ),
        ),
      );

      expect(tester.takeException(), isA<AssertionError>());
    });
  });

  group('the defaults, written by nobody', () {
    testWidgets('are the ones a scaffold that names neither knob gets', (
      tester,
    ) async {
      // **Every other row in this file goes through `_sheet`, which passes
      // `extendBodyBehindBottomBar` and `avoidsKeyboard` on every call** — so
      // the two constructor defaults are the one thing here that nothing was
      // testing, and flipping either of them left the whole file green. A
      // harness that passes the very defaults it is meant to be testing the
      // absence of is the blindness this package has already found in three
      // layers.
      //
      // The keyboard is up, so the two knobs point at different numbers: the
      // body stops above the bar rather than running behind it, and it clears
      // the 336pt inset rather than sitting under it.
      await tester.pumpWidget(
        onIPhone17Pro(
          viewInsets: kKeyboard,
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: const PanelContentScaffold(
              bottomBar: SizedBox(
                key: Key('bar'),
                height: _barHeight,
                width: double.infinity,
              ),
              body: SizedBox.expand(key: Key('body')),
            ),
          ),
        ),
      );

      expect(
        _rectOf(tester, 'body').bottom,
        closeTo(_frameBottom - 336, 1e-9),
        reason:
            'the body ran under the keyboard on the default an app gets by '
            'writing nothing',
      );
      expect(_rectOf(tester, 'bar').bottom, closeTo(_frameBottom, 1e-9));

      // And again with the keyboard down, because 336 is larger than the bar
      // and the maximum of the two hides which one produced it: an
      // `extendBodyBehindBottomBar` defaulting the wrong way is 538 either way
      // above, and 874 rather than 814 here.
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: const PanelContentScaffold(
              bottomBar: SizedBox(
                key: Key('bar'),
                height: _barHeight,
                width: double.infinity,
              ),
              body: SizedBox.expand(key: Key('body')),
            ),
          ),
        ),
      );
      // The keyboard going away moves no detent either, so the frame that
      // removes it relayouts nothing and the panel's own notification — raised
      // from inside that pass — lands at the end of it.
      await tester.pump();

      expect(
        _rectOf(tester, 'body').bottom,
        closeTo(_frameBottom - _barHeight, 1e-9),
        reason: 'the body ran behind the bar by default',
      );
    });

    testWidgets('and a body behind the bar with the keyboard declined fills', (
      tester,
    ) async {
      // The corner where both knobs are off: no band from the bar and no inset
      // from the keyboard is *nothing*, exactly — the one state in which the
      // body's height is the panel's own, and so the one that can see a zero
      // written as anything else.
      await tester.pumpWidget(
        _sheet(
          viewInsets: kKeyboard,
          extendBodyBehindBottomBar: true,
          avoidsKeyboard: false,
        ),
      );

      expect(_rectOf(tester, 'body').top, closeTo(_frameTop, 1e-9));
      expect(_rectOf(tester, 'body').bottom, closeTo(_frameBottom, 1e-9));
    });
  });

  group('a knob turned under a live scaffold', () {
    testWidgets('avoidsKeyboard, without rebuilding the panel under it', (
      tester,
    ) async {
      // A policy changed on a scaffold that is already on screen. Nothing else
      // in this file does it: every row builds its scaffold once with the
      // arguments it wants. The panel does not move — the keyboard was already
      // up and no detent depends on it — so the scaffold's constraints are
      // unchanged and the *only* thing that can relayout it is the delegate
      // saying its own configuration changed.
      Widget build({required bool avoidsKeyboard}) =>
          _sheet(viewInsets: kKeyboard, avoidsKeyboard: avoidsKeyboard);

      await tester.pumpWidget(build(avoidsKeyboard: true));
      expect(_rectOf(tester, 'body').bottom, closeTo(_frameBottom - 336, 1e-9));

      await tester.pumpWidget(build(avoidsKeyboard: false));

      expect(
        _rectOf(tester, 'body').bottom,
        closeTo(_frameBottom - _barHeight, 1e-9),
        reason: 'the body kept clearing a keyboard it was told to ignore',
      );
    });

    testWidgets('and a predicate replaced by one that disagrees with it', (
      tester,
    ) async {
      // A visibility swapped for another visibility, with the panel standing
      // still. Nothing else moves here — no metrics change, so the predicate is
      // not going to be asked again on its own — which makes the swap itself
      // the only thing that can notice, and `didUpdateWidget` the only place
      // that can ask.
      Widget build(Object identity, {required bool visible}) => _sheet(
        extendBodyBehindBottomBar: true,
        visibility: BottomBarVisibility.conditional(
          isVisible: (metrics) => visible,
          identity: identity,
        ),
      );

      await tester.pumpWidget(build('shown', visible: true));
      await tester.pumpAndSettle();
      expect(_rectOf(tester, 'bar').bottom, closeTo(_frameBottom, 0.5));

      await tester.pumpWidget(build('hidden', visible: false));
      await tester.pumpAndSettle();

      expect(
        _rectOf(tester, 'bar').top,
        greaterThanOrEqualTo(_frameBottom - 0.5),
        reason:
            'the scaffold was handed a policy that says no and never asked it',
      );
    });

    testWidgets('and a conditional replaced by one with no opinion comes back', (
      tester,
    ) async {
      // The variant swap that crosses the two halves of the policy: a bar that
      // is away because a predicate said so, handed to a variant that has no
      // predicate. There is nothing left to say no, so it has to return — and
      // it has to return without a duration, because the variant it arrived at
      // does not have one.
      Widget build(BottomBarVisibility visibility) =>
          _sheet(extendBodyBehindBottomBar: true, visibility: visibility);

      await tester.pumpWidget(
        build(
          BottomBarVisibility.conditional(
            isVisible: (metrics) => false,
            identity: 'never',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _rectOf(tester, 'bar').top,
        greaterThanOrEqualTo(_frameBottom - 0.5),
      );

      await tester.pumpWidget(build(const BottomBarVisibility.always()));
      await tester.pumpAndSettle();

      expect(
        _rectOf(tester, 'bar').bottom,
        closeTo(_frameBottom, 0.5),
        reason: 'a bar under a policy with no opinion is a bar that shows',
      );
    });

    testWidgets('and the visibility, which moves the bar and nothing else', (
      tester,
    ) async {
      Widget build(BottomBarVisibility visibility) =>
          _sheet(viewInsets: kKeyboard, visibility: visibility);

      await tester.pumpWidget(build(const BottomBarVisibility.natural()));
      expect(_rectOf(tester, 'bar').bottom, closeTo(_frameBottom, 1e-9));

      await tester.pumpWidget(build(const BottomBarVisibility.always()));

      expect(
        _rectOf(tester, 'bar').bottom,
        closeTo(_frameBottom - 336, 1e-9),
        reason:
            'the bar stayed behind the keyboard under a policy that '
            'says it must not',
      );
    });
  });

  group('what a moving panel costs the content', () {
    testWidgets('nothing: the bar is placed at layout, not at build', (
      tester,
    ) async {
      // A7's first instrument, as a property rather than a measurement. A
      // scaffold that read `PanelScope.metricsOf` in its own `build` would
      // rebuild the body on every frame of every settle — and the body is the
      // app's whole content. The position is read by the layout delegate
      // instead, which relayouts on the panel's own notifications.
      final body = Counter();
      final controller = PanelController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _sheet(
          controller: controller,
          body: counting(
            body,
            (context) => const SizedBox.expand(key: Key('body')),
          ),
        ),
      );

      final before = body.value;
      controller.animateTo(Detent.full);
      await tester.pumpAndSettle();

      expect(
        body.value,
        before,
        reason:
            'the body was rebuilt ${body.value - before} times by a panel '
            'moving between two detents',
      );
      expect(
        _rectOf(tester, 'bar').bottom,
        closeTo(_frameBottom, 0.5),
        reason: 'and the bar did follow the panel, without a build',
      );
    });
  });
}
