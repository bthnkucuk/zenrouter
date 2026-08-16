/// The content layout a panel needs and an app cannot write: a bar pinned to
/// the panel's own edge, and a body that knows about it.
///
/// **DESIGN.md A6.4 settles the shape rather than leaving it to be guessed.**
/// Read from `smooth_sheets-1.0.3`, the answer there is
/// `SheetContentScaffold(bottomBar:, bottomBarVisibility:,
/// extendBodyBehindBottomBar:)` with **three** visibility variants, and the
/// three consequences A6.4 draws are the three things this file is:
///
/// 1. **A panel needs a content scaffold**, because the bar has to be pinned to
///    the *viewport's* edge rather than to the content's, and only the panel
///    knows where that is. A `Column` cannot express it: the bar would follow
///    the body's height, and a body shorter than the panel would leave the bar
///    floating in the middle of the sheet.
/// 2. **Visibility is a policy with three variants**, so by A5 it is a named
///    type with all three tested at both ends, not a boolean.
/// 3. **`.conditional` requires the panel's position as a live listenable**,
///    which is what `PanelScope.metricsOf` publishes and why it exists.
///
/// **Where this diverges from the package it is ported from, and why.**
/// `smooth_sheets` carries an `ignoreBottomInset` flag on every variant, for
/// whether the bar should hide behind the keyboard. We take no flag: our panel's
/// detents cannot move with the keyboard by construction (A1, KB6), so the
/// keyboard covering the panel's attachment edge is exactly the same quantity as
/// the panel's attachment edge having left the viewport — and the two variants
/// that already exist are the two answers. [BottomBarVisibility.natural] rides
/// the edge and is covered; [BottomBarVisibility.always] stays clear. One
/// concept, no flag, and the row still ports.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../physics/motion.dart';
import 'scope.dart';

/// Whether the bar should be showing, in the panel state [metrics] describes.
///
/// Called on **every** metrics change — every frame of a drag, a fling and a
/// settle — so it must be cheap and it must be pure. It is the same contract
/// `Detent.resolve` is held to, for the same reason: iOS invokes its equivalent
/// seven times per layout pass (G9), and a predicate that allocated or read a
/// clock would do it sixty times a second here.
typedef BottomBarPredicate = bool Function(PanelMetrics metrics);

/// Where a [PanelContentScaffold.bottomBar] sits as the panel moves, and
/// whether it is showing at all.
///
/// **Two members, and every variant answers both.** [liftIn] is a position and
/// [isVisibleIn] is a fact, and keeping them apart is what stops the three
/// variants collapsing into two: `natural` and `always` differ only in the
/// first, `conditional` differs from `always` only in the second.
///
/// | variant | `liftIn` | `isVisibleIn` |
/// |:--|:--|:--|
/// | `natural` | 0 — rides the panel's attachment edge | always |
/// | `always` | clear of the departed panel and of the obstruction | always |
/// | `conditional` | `always`'s | the predicate |
///
/// **What separates `natural` from `always` in this slice is the keyboard, and
/// that is worth stating because it is the only thing that can.** The general
/// rule is that `always` lifts the bar over two things: the part of the panel
/// that has left the viewport (`PanelMetrics.edgeOffset`) and whatever the
/// system has put over the viewport's edge (`PanelMetrics.obstruction`). The
/// first is pinned at zero until dismissal lands, so today the two variants are
/// one layout on a panel with no keyboard up — which is why the tests for them
/// drive the pure functions at both ends rather than only pumping a live panel
/// that cannot tell them apart.
sealed class BottomBarVisibility {
  /// Const so the default costs no allocation and the two payload-free variants
  /// are canonicalised, which is what makes their equality free.
  const BottomBarVisibility();

  /// The bar sits at the panel's own attachment edge and goes wherever the
  /// panel goes.
  ///
  /// The default, matching the package this row is ported from, and the variant
  /// that adds nothing: the bar is a slot at the bottom of the sheet. Its two
  /// consequences are both real and both wanted by somebody — the bar leaves
  /// the screen with a panel being dismissed, and it sits *behind* the software
  /// keyboard, because the panel's edge is behind the software keyboard and
  /// this variant is the one that says "wherever the edge is".
  ///
  /// [BottomBarVisibility.always] is the answer to both, and a sheet with a text
  /// field in it almost certainly wants that one.
  const factory BottomBarVisibility.natural() = NaturalBottomBar;

  /// The bar stays at the last unobstructed edge of the viewport, whatever the
  /// panel is doing.
  ///
  /// Lifted clear of the part of the panel that has left the viewport and of
  /// whatever the system has drawn over that edge — so it stays put while a
  /// panel is dragged away, and it rides above the keyboard rather than behind
  /// it.
  ///
  /// The lift saturates at the panel's own extent: a 214pt peek under a 336pt
  /// keyboard lifts the bar 214pt and no further, because past that the bar
  /// would be outside the panel it belongs to.
  const factory BottomBarVisibility.always() = AlwaysBottomBar;

  /// The bar is shown while [isVisible] says so, and slides out when it stops.
  ///
  /// Positioned like [BottomBarVisibility.always] while it is showing. The
  /// predicate is re-evaluated on every metrics change — A6.4's own words — and
  /// its example is *"visible once at least half the sheet is"*, which here is
  /// `(metrics) => metrics.openProgress >= 0.5`.
  ///
  /// **[identity] is required, for `CustomDetent.identity`'s reason** (DESIGN.md
  /// §"Grafted from C", item 5). A closure is a fresh object on every build, so
  /// a visibility carrying one and nothing else compares unequal every frame:
  /// the scaffold's layout delegate would re-run for every rebuild and the
  /// animation controller would be re-seeded by `didUpdateWidget` on a
  /// predicate that had not changed. Two visibilities with the same identity are
  /// the same visibility, and the closure is not compared — which is the same
  /// bargain the detent makes.
  ///
  /// **Requires `extendBodyBehindBottomBar`**, and asserts it from
  /// [PanelContentScaffold.build], which is where both arguments are in hand —
  /// a visibility is constructed on its own and has no idea what scaffold it is
  /// about to be handed to. A bar that can leave has no fixed band to inset the
  /// body by, and a body that resized as the bar slid out would relayout its
  /// whole subtree for every frame of a 150ms animation. `smooth_sheets` asserts
  /// the same precondition, from the same place, for the same reason.
  const factory BottomBarVisibility.conditional({
    required BottomBarPredicate isVisible,
    required Object identity,
    Duration duration,
    Curve curve,
  }) = ConditionalBottomBar;

  /// How far the bar is held off the panel's attachment edge, in logical
  /// pixels, in the state [metrics] describes.
  ///
  /// Zero means flush with the edge. Never negative and never more than
  /// `metrics.extent`: the bar belongs to the panel, and a lift past the
  /// panel's leading edge would put it above a sheet it is supposed to be
  /// inside.
  ///
  /// This is a position and not a translation, so it is read at layout rather
  /// than at build — the scaffold's delegate re-runs on the panel's own
  /// notifications and the content is never rebuilt for a moving bar.
  double liftIn(PanelMetrics metrics);

  /// Whether the bar should be showing in the state [metrics] describes.
  bool isVisibleIn(PanelMetrics metrics);
}

/// [BottomBarVisibility.natural].
@immutable
final class NaturalBottomBar extends BottomBarVisibility {
  /// The bar rides the panel's attachment edge.
  const NaturalBottomBar();

  /// Zero, for every state there is — including the two that lift
  /// [AlwaysBottomBar]. This is the variant that adds nothing.
  @override
  double liftIn(PanelMetrics metrics) => 0;

  @override
  bool isVisibleIn(PanelMetrics metrics) => true;

  @override
  bool operator ==(Object other) => other is NaturalBottomBar;

  @override
  int get hashCode => (NaturalBottomBar).hashCode;

  @override
  String toString() => 'BottomBarVisibility.natural()';
}

/// [BottomBarVisibility.always].
@immutable
final class AlwaysBottomBar extends BottomBarVisibility {
  /// The bar stays at the last unobstructed edge of the viewport.
  const AlwaysBottomBar();

  /// The two things that separate the panel's attachment edge from the last
  /// unobstructed one, added and then held to the panel's own span.
  ///
  /// [PanelMetrics.edgeOffset] is how much of the panel has left the viewport
  /// and [PanelMetrics.obstruction] is what the system has drawn over that
  /// edge. Both, because an implementation reading either alone is right in two
  /// states out of four — and in this slice the `edgeOffset` half is the one no
  /// live panel can produce, which is why `content_scaffold_test.dart` drives
  /// this function directly at both.
  @override
  double liftIn(PanelMetrics metrics) =>
      (metrics.edgeOffset.px + metrics.obstruction.px).clamp(
        0.0,
        math.max(0.0, metrics.extent.px),
      );

  @override
  bool isVisibleIn(PanelMetrics metrics) => true;

  @override
  bool operator ==(Object other) => other is AlwaysBottomBar;

  @override
  int get hashCode => (AlwaysBottomBar).hashCode;

  @override
  String toString() => 'BottomBarVisibility.always()';
}

/// [BottomBarVisibility.conditional].
@immutable
final class ConditionalBottomBar extends BottomBarVisibility {
  /// Shows the bar while [isVisible] holds.
  ///
  /// [duration] is `kPanelInteractiveDuration` — the 150ms this package already
  /// pins for `PanelMotion.interactive`, reused rather than re-invented so that
  /// a bar appearing and a panel answering a finger take the same time. It is a
  /// duration and a [Curve] rather than a `PanelMotion` because a bar's
  /// appearance has no velocity to carry: nothing was moving it before, and a
  /// spring seeded from zero is a curve with extra machinery.
  const ConditionalBottomBar({
    required this.isVisible,
    required this.identity,
    this.duration = kPanelInteractiveDuration,
    this.curve = Curves.easeInOut,
  });

  /// The predicate, re-evaluated on every metrics change.
  final BottomBarPredicate isVisible;

  /// What makes two of these the same one. See the factory's doc.
  final Object identity;

  /// How long the bar takes to slide in or out.
  final Duration duration;

  /// The shape of that slide.
  final Curve curve;

  /// [AlwaysBottomBar]'s, because a conditional bar that is showing *is* an
  /// always bar. The difference between the two is [isVisibleIn] and nothing
  /// else.
  @override
  double liftIn(PanelMetrics metrics) =>
      const AlwaysBottomBar().liftIn(metrics);

  @override
  bool isVisibleIn(PanelMetrics metrics) => isVisible(metrics);

  /// Over [identity], [duration] and [curve] — deliberately **not** over
  /// [isVisible]. See the factory's doc: comparing the closure is what makes
  /// every rebuild look like a new policy.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConditionalBottomBar &&
          other.identity == identity &&
          other.duration == duration &&
          other.curve == curve;

  @override
  int get hashCode =>
      Object.hash(ConditionalBottomBar, identity, duration, curve);

  @override
  String toString() =>
      'BottomBarVisibility.conditional($identity, $duration, $curve)';
}

/// A body and a bar, laid out in the panel's own frame.
///
/// **The layout, as one rule per slot.**
///
/// - The **bar** is laid out loose, takes its own height, and is placed so that
///   its far edge sits `bottomBarVisibility.liftIn(metrics)` from the panel's
///   attachment edge. While it is hidden it is placed one bar-height *outside*
///   the frame instead, and the two positions are interpolated over
///   `ConditionalBottomBar.duration` — so hiding always finishes with the bar
///   fully gone, whatever it was lifted over.
/// - The **body** fills the frame less its bottom inset, which is
///
///   ```
///   max(
///     extendBodyBehindBottomBar ? 0 : barHeight + liftIn(metrics),
///     avoidsKeyboard ? metrics.obstruction : 0,
///   )
///   ```
///
///   The maximum, and not the sum: with a lifted bar the keyboard is already
///   underneath it, and adding both would inset the body twice for one
///   obstruction. Written as a maximum, the four corners of the two knobs are
///   four arithmetic answers rather than four cases.
///
/// **Neither the body nor the bar is rebuilt while the panel moves.** The
/// position is read at *layout* — the layout delegate takes the panel's
/// controller as its `relayout` listenable — so a settle costs one layout of
/// this subtree per frame and no builds at all. A scaffold that read
/// `PanelScope.metricsOf` in its own `build` would rebuild the body sixty times
/// a second, which is the cost A7's first instrument is pointed at.
///
/// The one exception is `extendBodyBehindBottomBar`, which makes the body's
/// bottom `MediaQuery.padding` depend on a height only layout knows — so the
/// body is wrapped in a builder that reads its own constraints, and rebuilds
/// when they change. `Scaffold` pays exactly this and only under
/// `extendBody`/`extendBodyBehindAppBar` (`material/scaffold.dart`'s
/// `_BodyBuilder`), and the default here is the same default: off.
///
/// **The keyboard is handled here and not by the app** (A6.6). `avoidsKeyboard`
/// insets the body by the panel's *own* obstruction — the re-derived number
/// from `PanelMediaQuery`, never `MediaQuery.viewInsetsOf(context).bottom`,
/// which measures the keyboard against the screen and is wrong the moment the
/// panel is not full height.
class PanelContentScaffold extends StatelessWidget {
  /// Lays [body] out in the panel, with [bottomBar] pinned to its edge.
  const PanelContentScaffold({
    super.key,
    required this.body,
    this.bottomBar,
    this.bottomBarVisibility = const BottomBarVisibility.natural(),
    this.extendBodyBehindBottomBar = false,
    this.avoidsKeyboard = true,
  });

  /// The panel's content. Gets the frame less whatever the bar and the keyboard
  /// take.
  final Widget body;

  /// The bar pinned to the panel's attachment edge, or null for no bar.
  ///
  /// Any widget: its height is measured rather than declared, so a
  /// `PreferredSizeWidget` is not required and a bar that changes height does
  /// not need to announce it.
  final Widget? bottomBar;

  /// Where the bar sits as the panel moves, and whether it is showing.
  ///
  /// Defaults to [BottomBarVisibility.natural], matching the package this
  /// capability is ported from, so a port that does not name a visibility gets
  /// the behaviour it was written against. A sheet with a text field in it
  /// almost certainly wants [BottomBarVisibility.always] instead — see that
  /// variant's doc for why the default was not flipped.
  final BottomBarVisibility bottomBarVisibility;

  /// Whether the body extends under the bar rather than stopping above it.
  ///
  /// When true the body is given the whole frame and told about the overlap
  /// through its own `MediaQuery.padding.bottom`, so a `ListView` inside it can
  /// scroll under a translucent bar and still end clear of it. Required by
  /// [BottomBarVisibility.conditional], which has no fixed band to inset by.
  final bool extendBodyBehindBottomBar;

  /// Whether the body is inset by whatever the system has drawn over the
  /// panel's attachment edge.
  ///
  /// True by default, which is `Scaffold.resizeToAvoidBottomInset`'s default
  /// and A6.6's requirement: a `TextField` in a panel is the common case, and
  /// the common case takes no configuration. False is the other end of the
  /// policy and is what a panel whose body draws its own keyboard accessory
  /// wants.
  final bool avoidsKeyboard;

  @override
  Widget build(BuildContext context) {
    assert(
      bottomBarVisibility is! ConditionalBottomBar || extendBodyBehindBottomBar,
      'BottomBarVisibility.conditional needs extendBodyBehindBottomBar: true. '
      'A bar that can leave has no fixed band to inset the body by, so a body '
      'that stopped above it would have to resize as the bar slid out — a '
      'relayout of the whole content subtree for every frame of a '
      '${(bottomBarVisibility as ConditionalBottomBar).duration.inMilliseconds}'
      'ms animation. Extend the body behind the bar and let it read the '
      'overlap from its own MediaQuery.padding.bottom instead.',
    );
    // `PanelScope.of` and not `metricsOf`: this depends on the controller's
    // *identity*, which changes at most once in a panel's life, so a moving
    // panel never marks this element dirty. The position is read at layout, by
    // the delegate below.
    return _PanelScaffold(
      controller: PanelScope.of(context),
      body: body,
      bottomBar: bottomBar,
      visibility: bottomBarVisibility,
      extendBody: extendBodyBehindBottomBar,
      avoidsKeyboard: avoidsKeyboard,
    );
  }
}

/// The two things a [PanelContentScaffold] lays out.
enum _Slot {
  /// The panel's content.
  body,

  /// The bar pinned to the panel's attachment edge.
  bar,
}

/// The stateful half: the hide animation, and the relay the delegate relayouts
/// on.
///
/// Split out because [PanelContentScaffold] is a `StatelessWidget` by design —
/// it is the thing an app writes, and an app should be able to write it in a
/// `const` — while a bar that slides in and out needs an `AnimationController`
/// and therefore a `State` and a vsync.
class _PanelScaffold extends StatefulWidget {
  const _PanelScaffold({
    required this.controller,
    required this.body,
    required this.bottomBar,
    required this.visibility,
    required this.extendBody,
    required this.avoidsKeyboard,
  });

  final PanelController controller;
  final Widget body;
  final Widget? bottomBar;
  final BottomBarVisibility visibility;
  final bool extendBody;
  final bool avoidsKeyboard;

  @override
  State<_PanelScaffold> createState() => _PanelScaffoldState();
}

class _PanelScaffoldState extends State<_PanelScaffold>
    with SingleTickerProviderStateMixin {
  /// How far in the bar is: 1 fully shown, 0 one bar-height outside the frame.
  ///
  /// Fully *outside*, rather than merely lowered by whatever the bar had been
  /// lifted over, so that hiding finishes the same way in every state the panel
  /// can be in.
  late final AnimationController hide;

  /// What the delegate relayouts on: the panel's position, and this animation.
  ///
  /// Both are safe to mark layout from. `PanelController` holds an announcement
  /// raised inside a frame's persistent-callback phase until the end of that
  /// frame — see [PanelController.value] — and an `AnimationController` only
  /// ever changes value from the transient-callback phase, before the frame's
  /// work begins.
  ///
  /// Not `final`: an app that swaps the panel's controller swaps what this
  /// listens to, and a delegate still relayouting on the old one would hold the
  /// bar wherever the departed panel left it.
  late Listenable relayout;

  /// The predicate's last answer, so a settle that does not change it costs one
  /// bool comparison rather than a re-seeded animation every frame.
  late bool showing;

  @override
  void initState() {
    super.initState();
    showing = wanted;
    hide = AnimationController(
      vsync: this,
      duration: durationOf(widget.visibility),
      // Seeded rather than animated into: a conditional bar whose predicate is
      // already false at the first build has never been on screen, and sliding
      // it out on the panel's first frame would announce a bar that was never
      // there.
      value: showing ? 1 : 0,
    );
    relayout = Listenable.merge(<Listenable>[widget.controller, hide]);
    widget.controller.addListener(evaluate);
  }

  @override
  void didUpdateWidget(_PanelScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller.removeListener(evaluate);
      widget.controller.addListener(evaluate);
      relayout = Listenable.merge(<Listenable>[widget.controller, hide]);
    }
    if (widget.visibility != oldWidget.visibility) {
      hide.duration = durationOf(widget.visibility);
      evaluate();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(evaluate);
    hide.dispose();
    super.dispose();
  }

  /// Whether the bar should be showing right now.
  ///
  /// Reads the predicate every time it is asked, which is the point: A6.4's
  /// words are *"re-evaluated whenever the metrics change"*, and this is called
  /// from the panel's own notification.
  bool get wanted {
    final metrics = widget.controller.value;
    return metrics == null || widget.visibility.isVisibleIn(metrics);
  }

  /// How long this visibility takes to slide in or out — zero for the two that
  /// never do.
  Duration durationOf(BottomBarVisibility visibility) => switch (visibility) {
    ConditionalBottomBar(:final duration) => duration,
    NaturalBottomBar() || AlwaysBottomBar() => Duration.zero,
  };

  /// The shape of that slide.
  Curve curveOf(BottomBarVisibility visibility) => switch (visibility) {
    ConditionalBottomBar(:final curve) => curve,
    NaturalBottomBar() || AlwaysBottomBar() => Curves.linear,
  };

  /// Re-asks the predicate and starts the slide if its answer changed.
  ///
  /// Called from the panel's notification, which can arrive from inside a
  /// layout pass — `PanelModel.applyLayout` commits and notifies from within
  /// `RenderPanelViewport.performLayout`. Starting an `AnimationController` from
  /// there is safe: it schedules a frame callback and changes no value, so
  /// nothing is marked dirty until the next frame's transient phase. That is
  /// why the animation is driven here and the *relayout* is driven through
  /// [_PanelRelay], which cannot be.
  void evaluate() {
    final next = wanted;
    if (next == showing) return;
    showing = next;
    hide.animateTo(
      next ? 1 : 0,
      duration: durationOf(widget.visibility),
      curve: curveOf(widget.visibility),
    );
  }

  @override
  Widget build(BuildContext context) => CustomMultiChildLayout(
    delegate: _PanelScaffoldLayout(
      controller: widget.controller,
      visibility: widget.visibility,
      hide: hide,
      extendBody: widget.extendBody,
      avoidsKeyboard: widget.avoidsKeyboard,
      relayout: relayout,
    ),
    children: <Widget>[
      LayoutId(
        id: _Slot.body,
        // The body is handed down as the identical widget instance it arrived
        // as unless `extendBody` is on, so a rebuild of this scaffold does not
        // rebuild the app's content — `Element.updateChild` short-circuits on
        // an unchanged widget.
        child: widget.extendBody
            ? _PanelScaffoldBody(body: widget.body)
            : widget.body,
      ),
      if (widget.bottomBar case final bar?) LayoutId(id: _Slot.bar, child: bar),
    ],
  );
}

/// The body's constraints, carrying the one number only layout knows.
///
/// `Scaffold._BodyBoxConstraints`' shape and its reason: a body extended behind
/// the bar has to be told how much of it the bar covers, and the only place that
/// number exists is inside [_PanelScaffoldLayout.performLayout]. Carrying it on
/// the constraints is what lets a `LayoutBuilder` in the body read it — and what
/// makes the body rebuild when it changes, since [==] is what `LayoutBuilder`
/// compares.
class _PanelBodyConstraints extends BoxConstraints {
  const _PanelBodyConstraints({
    required double width,
    required double height,
    required this.coveredByBar,
  }) : super(
         minWidth: width,
         maxWidth: width,
         minHeight: height,
         maxHeight: height,
       );

  /// How many logical pixels of the body's bottom edge the bar is over.
  final double coveredByBar;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _PanelBodyConstraints &&
          super == other &&
          other.coveredByBar == coveredByBar;

  @override
  int get hashCode => Object.hash(super.hashCode, coveredByBar);
}

/// The body, told about the bar it is extended behind.
///
/// Only built under `extendBodyBehindBottomBar`, and that is the whole of the
/// cost: a `LayoutBuilder` rebuilds whenever its constraints change, and a
/// panel's constraints change on every frame it moves. `Scaffold` pays exactly
/// this and only under `extendBody`/`extendBodyBehindAppBar`; the default here
/// is the same default.
class _PanelScaffoldBody extends StatelessWidget {
  const _PanelScaffoldBody({required this.body});

  final Widget body;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // A cast and not a test-with-a-fallback. The only thing that lays this
      // widget out is `_PanelScaffoldLayout`, which always sends the overlap;
      // a `?: 0.0` beside it would be an untestable branch that quietly
      // published the wrong padding on the day something else did.
      final covered = (constraints as _PanelBodyConstraints).coveredByBar;
      final ambient = MediaQuery.of(context);
      return MediaQuery(
        // The larger of the two, not their sum: the bar may be sitting over the
        // home indicator, and a body inset for both would clear one obstruction
        // twice.
        data: ambient.copyWith(
          padding: ambient.padding.copyWith(
            bottom: math.max(ambient.padding.bottom, covered),
          ),
        ),
        child: body,
      );
    },
  );
}

/// The one rule per slot, applied in the panel's own frame.
///
/// It reads the panel's position out of [controller] **here**, at layout, and
/// not out of a field it was handed at build time. That is what makes a settle
/// cost one layout of this subtree per frame and no builds at all — and it is
/// also what makes [_PanelRelay]'s deferral harmless, since a relayout that
/// arrives a frame late still reads where the panel is when it runs.
class _PanelScaffoldLayout extends MultiChildLayoutDelegate {
  _PanelScaffoldLayout({
    required this.controller,
    required this.visibility,
    required this.hide,
    required this.extendBody,
    required this.avoidsKeyboard,
    required super.relayout,
  });

  final PanelController controller;
  final BottomBarVisibility visibility;
  final Animation<double> hide;
  final bool extendBody;
  final bool avoidsKeyboard;

  @override
  void performLayout(Size size) {
    // Non-null inside a panel, and there is no outside: `PanelScope.of` refuses
    // where there is no panel, and a panel attaches its controller before its
    // content is first built. The assert names the one arrangement that can
    // still get here — a hand-built `PanelScope` over a controller no panel has
    // taken — because a bare null check names nothing, and a silent fallback
    // would lay the bar out at the wrong place rather than say so.
    assert(
      controller.value != null,
      'A PanelContentScaffold was laid out under a PanelScope whose controller '
      'has no panel, so there is no position to place its bar against. Put the '
      'scaffold inside a Panel, or give that scope a controller a Panel holds.',
    );
    final metrics = controller.value!;
    final lift = visibility.liftIn(metrics);
    final obstruction = metrics.obstruction.px;

    // Loose on the span axis, so a bar's height is measured rather than
    // declared and a `PreferredSizeWidget` is not required; tight across, so a
    // bar spans the panel the way the panel spans its viewport.
    var barHeight = 0.0;
    if (hasChild(_Slot.bar)) {
      barHeight = layoutChild(
        _Slot.bar,
        BoxConstraints(
          minWidth: size.width,
          maxWidth: size.width,
          maxHeight: size.height,
        ),
      ).height;
    }

    // Two positions and one interpolation between them: `lift` off the panel's
    // attachment edge while showing, one whole bar-height past it while hidden.
    final shown = size.height - lift;
    final hidden = size.height + barHeight;
    final barBottom = hidden + (shown - hidden) * hide.value;
    if (hasChild(_Slot.bar)) {
      positionChild(_Slot.bar, Offset(0, barBottom - barHeight));
    }

    // The band the bar takes out of the frame, and whatever the system has put
    // over the panel's edge — the *maximum*, not the sum. A lifted bar already
    // has the keyboard underneath it, so adding both would inset the body twice
    // for one obstruction.
    final band = extendBody ? 0.0 : barHeight + lift;
    final keyboard = avoidsKeyboard ? obstruction : 0.0;
    final inset = math.max(band, keyboard).clamp(0.0, size.height);

    layoutChild(
      _Slot.body,
      _PanelBodyConstraints(
        width: size.width,
        height: size.height - inset,
        // Never negative and so never clamped: the bar's top edge is at worst
        // the frame's own bottom, which is where a fully hidden bar is placed.
        coveredByBar: size.height - (barBottom - barHeight),
      ),
    );
    positionChild(_Slot.body, Offset.zero);
  }

  @override
  bool shouldRelayout(_PanelScaffoldLayout oldDelegate) =>
      !identical(oldDelegate.controller, controller) ||
      !identical(oldDelegate.hide, hide) ||
      oldDelegate.visibility != visibility ||
      oldDelegate.extendBody != extendBody ||
      oldDelegate.avoidsKeyboard != avoidsKeyboard;
}
