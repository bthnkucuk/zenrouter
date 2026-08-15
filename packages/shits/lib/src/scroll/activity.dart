/// The two scroll-side activities a panel needs, and nothing else.
///
/// DESIGN.md §6 promises this file holds "`FusedBallisticActivity` + the three
/// placeholder activities". It holds one and a half, and the missing ones are a
/// result rather than an omission:
///
/// - **The drag placeholder is the framework's.** `DragScrollActivity` already
///   dispatches `ScrollStart` and `ScrollEnd`, and `ScrollUpdate` and
///   `Overscroll` come out of `setPixels` on the content's share. A subclass that
///   moved no pixels and re-dispatched the same notifications would be a copy of
///   `DragScrollActivity` with the copy's bugs.
/// - **The hold placeholder is the framework's too**, for the same reason:
///   `HoldScrollActivity` is what `ScrollPositionWithSingleContext.hold` returns
///   and it already implements `ScrollHoldController`.
/// - **There is no `ScrollHoldActivity` on the panel side, and there cannot be
///   one from here.** DESIGN.md §1.2 lists it as a third `ScrollDrivenActivity`
///   leaf; that hierarchy is `sealed`, so a leaf can only be added in
///   `model/activity.dart`. It would also be a leaf the model layer's own rule
///   deletes: `test/model/correction_test.dart` says to merge two leaves with
///   identical corrections *and* identical tick behaviour, and a hold answers
///   `LayoutCorrection.freeze`, reports `isUserDriven`, does not tick and moves
///   nothing — which is `ScrollDragActivity` with no deltas yet. So a hold
///   *is* a drag of zero deltas here, and that is the finding rather than the
///   workaround.
///
/// What is left is the fused fling, which the framework has no shape for because
/// no framework activity writes two things.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../model/activity.dart';
import '../model/panel_model.dart';
import '../physics/fused_simulation.dart';
import 'link.dart';
import 'position.dart';

/// A finger on a scrollable inside the panel, split between the two of them.
///
/// The `Drag` `PanelScrollPosition.drag` hands back to the gesture recogniser.
/// It owns the decision; the two things it drives own the motion:
///
/// - the panel's share goes to a `ScrollDragActivity` on the model, which
///   accumulates it un-resisted and rubber-bands whatever falls outside the
///   travel;
/// - the content's share goes to a `ScrollDragController`, the framework's own
///   drag, so velocity tracking, `carriedMomentum`, the iOS motion-start
///   threshold and every `ScrollUpdateNotification` keep working exactly as they
///   do outside a panel.
///
/// **Constructing this is the only way to get either half**, which is DESIGN.md
/// §3.2's "a half-installed handoff is not constructible" expressed where this
/// slice can express it: `ScrollDrivenActivity` is sealed into `model/` and
/// cannot be given a second required constructor argument from here, so the
/// pairing is enforced by there being exactly one call site — `PanelScrollPosition.drag`.
///
/// **A zero content share still forwards a zero-delta update**, and that is not
/// a nicety. `ScrollDragController` keeps a `_lastNonStationaryTimestamp` and
/// applies `physics.dragStartDistanceMotionThreshold` after a stationary pause
/// (iOS only); a drag whose deltas the panel swallowed entirely would look
/// stationary to it, and the first delta the content *did* get would be eaten by
/// the threshold. The list would then stutter at exactly the moment the panel
/// reached its largest detent, which reads as a physics bug and is a bookkeeping
/// one.
final class PanelDrag implements Drag {
  /// Splits [details]-driven motion between [panel] and [content].
  ///
  /// [panel] is the model-side activity — already installed on the model by the
  /// caller, because installing it is what disposes whatever was running.
  /// [content] is the framework's drag for the same gesture.
  PanelDrag({
    required this.position,
    required this.panel,
    required this.content,
  });

  /// The position this drag belongs to, and the link it arbitrates through.
  ///
  /// Mutable, with [panel], because Flutter replaces a `ScrollPosition` outright
  /// when the physics or the controller `runtimeType` changes
  /// (`scrollable.dart:686-698`) while the `Drag` the recogniser is holding —
  /// this object — survives the swap. See [rebind].
  PanelScrollPosition position;

  /// The panel's half of the gesture.
  ///
  /// Mutable for [rebind]'s reason: `ScrollDrivenActivity.position` is `final`
  /// in a sealed hierarchy this layer does not own, so `absorb` repoints the
  /// binding by *replacing* the activity — and this field has to follow it or
  /// the release ends an activity the model threw away.
  ScrollDragActivity panel;

  /// The content's half.
  ///
  /// Not mutable, and the asymmetry is the framework's: `ScrollDragController`
  /// is repointed in place by `ScrollPositionWithSingleContext.absorb`
  /// (`:100-103`), which moves the object across and calls `updateDelegate` on
  /// it. It is the same object throughout, which is why the content half of a
  /// swapped gesture has always kept working and the panel half has not.
  final ScrollDragController content;

  /// Points this drag at the position that absorbed the one it was built on.
  ///
  /// Called from `PanelScrollPosition.absorb`, which is the only place both
  /// halves of the swap are known. Without it [position] and [panel] are the
  /// disposed pair: `end` then installs a `ScrollBallisticActivity` on the model
  /// bound to a position nothing drives — `FusedBallisticActivity` is the only
  /// thing that ticks a scroll-driven activity and the new position's
  /// `goBallistic` refuses to build one, because the fling it finds is not its
  /// own — so `isTicking` stays true for ever and the panel is parked wherever
  /// the finger left it, off every detent, answering `freeze` to every rotation
  /// and keyboard after it.
  void rebind({
    required PanelScrollPosition position,
    required ScrollDragActivity panel,
  }) {
    // [panel] is the half that has to move. [position] is belt and braces, in
    // the shape `PanelScrollPosition.absorb`'s own `link` assignment uses: it is
    // read here only for its `link`, and `PanelScrollController.attach`
    // refreshes that on the *old* position before a replacement is ever built —
    // so both objects answer the same link at every reachable call and deleting
    // this line leaves the suite green. It is here because a `Drag` pointing at
    // a disposed position is a use-after-free waiting for the first caller who
    // reads something else off it.
    this.position = position;
    this.panel = panel;
  }

  /// Forwards [details] to [content], verbatim.
  ///
  /// **Nothing is split here**, and that is the correction to DESIGN.md's shape
  /// rather than an omission. The delta on a `DragUpdateDetails` is the raw
  /// pointer's: `ScrollDragController.update` still has to reverse it for
  /// `axisDirectionIsReversed` (`scroll_activity.dart:321`) and run it through
  /// `_adjustForScrollStartThreshold`, iOS's 40 lines of motion-start
  /// bookkeeping. Splitting above that means reimplementing both, and getting
  /// the second one subtly wrong is invisible until a list creeps under a
  /// resting finger.
  ///
  /// So the delta is split one layer down, in
  /// `PanelScrollPosition.applyUserOffset`, which is what `content` calls with a
  /// delta the framework has finished preparing. This class exists for the
  /// gesture's *lifetime*, not for its deltas.
  @override
  void update(DragUpdateDetails details) => content.update(details);

  /// Ends the gesture, which produces exactly one fused ballistic.
  ///
  /// Both halves are told, and only one simulation results. `content.end`
  /// reaches `PanelScrollPosition.goBallistic` with the finger's velocity in
  /// scroll space — the recogniser's estimate, not an integral of the reduced
  /// deltas — and that override is where the fused axis is built. The panel side
  /// is ended first so the model is holding a `ScrollBallisticActivity` by the
  /// time `goBallistic` looks at it, which is how `goBallistic` tells a fused
  /// release from a bare scroll fling without being passed a flag.
  @override
  void end(DragEndDetails details) {
    final link = position.link;
    // The panel first, so the model is holding a `ScrollBallisticActivity` by
    // the time `content.end` reaches `PanelScrollPosition.goBallistic` — which
    // is how that override tells a fused release from a bare scroll fling
    // without being passed a flag.
    //
    // Only into a gesture the model is still holding, which is the same identity
    // test `PanelScrollPosition.applyUserOffset` makes on every delta and for
    // the same reason: a programmatic `animateTo` mid-drag replaces the model's
    // activity, and ending the one it replaced would install a fling on top of
    // a spring that already owns the panel — and would bind that fling to a
    // position `goBallistic` will refuse, leaving nothing to tick it.
    //
    // The velocity is the recogniser's estimate of the *finger*, converted by
    // the anchor, and not an integral of the reduced deltas: a gesture the panel
    // only took half of was still made at the speed the hand was moving.
    if (identical(link.model.activity, panel)) {
      panel.end(
        link.anchor.fromPointer(
          details.velocity.pixelsPerSecond,
          link.textDirection,
        ),
      );
    }
    content.end(details);
  }

  /// Cancels the gesture: the content stops where it is and the panel settles at
  /// the nearest detent.
  ///
  /// Through `ScrollDragActivity.cancel`, which is `goBallistic` of zero — a
  /// release of zero projects to where the panel already is, so the detent
  /// nearest the projection is the detent nearest the panel, and there is no
  /// second "which detent is nearest" written down.
  @override
  void cancel() {
    // The same guard [end] makes, for the same reason: `cancel` is
    // `goBallistic` of zero, and stomping a spring the model started while the
    // finger was down would drop a programmatic move on the floor.
    if (identical(position.link.model.activity, panel)) panel.cancel();
    content.cancel();
  }

  // **There is deliberately no `dispose` here**, and the absence is the finding
  // rather than an omission. A mirror of `ScrollDragController.dispose` reads
  // like the obvious thing to write — `Drag` declares none, and the wrapped
  // controller has one — but nothing may call it: the framework disposes the
  // controller itself, from `ScrollPositionWithSingleContext.beginActivity`
  // (`:280`) and `dispose` (`:121`), and moves it across in `absorb`
  // (`:100-103`). A `PanelDrag.dispose` that forwarded to `content.dispose`
  // would therefore be dead until somebody followed its own doc comment, and
  // the first time they did it would dispose the controller twice. The
  // model-side half needs no releasing either: whatever replaces it on the
  // model disposes it, which is `PanelModel.beginActivity`'s contract.
}

/// One fling across the panel and the list inside it: one simulation, one
/// ticker, two things written per frame.
///
/// `BallisticScrollActivity` writes `pixels`. This writes `pixels` **and** the
/// panel's extent, from one [FusedSimulation] sampled once per frame, which is
/// the whole of DESIGN.md §3.3's claim and the whole of falsification criterion
/// 4 — *the fused ballistic needs more than one `Simulation` or more than one
/// ticker*.
///
/// **Where the panel's clock comes from, and the alternative that was not
/// taken.** The model holds a `ScrollBallisticActivity` for the life of this
/// activity, because that is what makes the panel answer
/// `LayoutCorrection.resnap` to a layout change mid-fling. That activity keeps
/// its own elapsed time and closes its own re-snap window, so *something* must
/// call `PanelModel.tick`. Two readings:
///
/// 1. The widget layer's ticker drives the model, as it does for a self-driven
///    settle, and this activity drives only the pixels. Two tickers for one
///    fling, which the falsification criterion forbids.
/// 2. **This activity is the only ticker**: each frame it advances the model's
///    clock with the same delta it samples the simulation at, and it ends when
///    either the simulation is done *or* the model has replaced the activity
///    this one installed.
///
/// The second is taken. The second clause is the part worth reading twice:
/// `ScrollBallisticActivity.isTicking` is `isResnapping || !friction.isDone`,
/// seeded from the same release, so it can run out before or after the fused
/// simulation depending on whether a spring was added after the seam. When it
/// runs out first it hands the panel to a self-driven settle, and this activity
/// must stop writing the extent at that moment or it would be fighting a spring
/// it does not own. Observing the model rather than predicting it is what makes
/// the two clocks agree without either one knowing the other's arithmetic.
///
/// `fused_ballistic_test.dart` counts both — one `Simulation` constructed, one
/// `Ticker` started — because a design that says "one" and ships two is the
/// commonest way this shape goes wrong, and neither count is visible from the
/// behaviour.
final class FusedBallisticActivity extends ScrollActivity {
  /// Runs [simulation] against [delegate], writing both halves each frame.
  ///
  /// [panel] is the model-side activity this fling installed. It is passed
  /// rather than looked up so that "the model has replaced it" is a comparison
  /// against a value this activity holds, and not a type test that a second
  /// fused fling would also satisfy.
  FusedBallisticActivity({
    required PanelScrollPosition delegate,
    required this.simulation,
    required this.panel,
    required TickerProvider vsync,
  }) : _link = delegate.link,
       super(delegate) {
    _ticker = vsync.createTicker(_tick)..start();
  }

  /// The arbiter, held rather than reached through the delegate because
  /// `ScrollActivity.delegate` is a `ScrollActivityDelegate` and the panel is on
  /// the other side of it.
  ///
  /// A delegate swap replaces this activity outright — `updateDelegate` calls
  /// [resetActivity], which builds a fresh fling on the new position — so this
  /// cannot go stale while it is being read.
  final PanelScrollLink _link;

  /// The panel this fling is moving.
  PanelModel get _model => _link.model;

  /// How long this activity has been running, for the frame delta the model's
  /// clock is advanced by.
  Duration _elapsed = Duration.zero;

  /// [_elapsed] in seconds, which is what a `Simulation` is sampled in.
  double get _seconds =>
      _elapsed.inMicroseconds / Duration.microsecondsPerSecond;

  /// The one ticker, from `ScrollContext.vsync` — the `Scrollable`'s own state,
  /// so the fling is bound to the widget that owns the list and stops when it
  /// goes away, exactly as `BallisticScrollActivity`'s is.
  ///
  /// Created here rather than in [dispose]'s absence: a `Ticker` that is never
  /// constructed is a "one ticker" claim nothing can count, and
  /// `fused_ballistic_test.dart` counts `TickerProvider.createTicker` calls
  /// because two tickers for one fling is invisible from the behaviour.
  late final Ticker _ticker;

  /// One frame: sample the simulation once, write both halves, advance the
  /// model's clock by the same delta.
  ///
  /// The whole of the fused claim is in this method's *arity*. Two writes, one
  /// sample, one `Duration`.
  void _tick(Duration elapsed) {
    final delta = elapsed - _elapsed;
    _elapsed = elapsed;
    // The panel's clock, advanced by the same delta the simulation is sampled
    // at. The model holds a `ScrollBallisticActivity` for the life of this one —
    // that is what makes the panel answer `LayoutCorrection.resnap` to a layout
    // change mid-fling — and that activity keeps its own elapsed time and closes
    // its own re-snap window, so something has to advance it. Two tickers would
    // be the alternative, and falsification criterion 4 forbids that.
    _model.tick(delta);
    // Observed rather than predicted: `ScrollBallisticActivity.isTicking` runs
    // out on its own schedule, and when it does it hands the panel to a
    // self-driven settle. Writing the extent after that is fighting a spring
    // this activity does not own.
    if (!identical(_model.activity, panel)) {
      delegate.goIdle();
      return;
    }
    final sample = simulation.sample(_seconds);
    _model.applyExtent(sample.extent);
    // `setPixels` rather than a write, so `applyBoundaryConditions`,
    // `didUpdateScrollPositionBy` and every notification behave as they do under
    // the framework's own ballistic — and a non-zero return is an overscroll the
    // axis did not predict, which ends the fling exactly where
    // `BallisticScrollActivity` ends it.
    final overscroll = delegate.setPixels(sample.scrollPixels);
    if (overscroll != 0.0 || simulation.isDone(_seconds)) delegate.goIdle();
  }

  /// The one simulation.
  final FusedSimulation simulation;

  /// The model-side activity that makes the panel answer `resnap` while this
  /// runs.
  final ScrollBallisticActivity panel;

  /// True — this is a fling, and pointers should not land in the content mid-flight.
  @override
  bool get shouldIgnorePointer => true;

  /// True.
  @override
  bool get isScrolling => true;

  /// The content's share of the fused velocity, in scroll px/s.
  ///
  /// Zero below the seam: the panel is what is moving there, and reporting the
  /// panel's speed as the *scroll* velocity would hand a `Scrollbar` and every
  /// `UserScrollNotification` a number about something they cannot see.
  @override
  double get velocity => simulation.x(_seconds) < simulation.axis.seam.px
      ? 0.0
      : _link.scrollDeltaOfExtent(simulation.dx(_seconds));

  /// Restarts against the delegate this activity was moved to.
  @override
  void resetActivity() => delegate.goBallistic(velocity);

  /// Re-projects the fling when the content's own bounds move under it.
  ///
  /// A lazy viewport discovering another screenful changes `maxScrollExtent`,
  /// which moves `FusedAxis.end` and rescales nothing else — the seam is the
  /// panel's travel and does not move. So a fling already past the seam keeps
  /// its friction and simply has further to go, and one below it is untouched.
  /// The case that needs re-projection is the panel's, and that is
  /// `LayoutCorrection.resnap`'s, on the model, inside its own window.
  @override
  void applyNewDimensions() {
    // Deliberately nothing, where `BallisticScrollActivity` re-projects. A lazy
    // viewport finding another screenful moves `FusedAxis.end` and nothing else
    // — the seam is the panel's travel — so a fling past the seam simply has
    // further to go and one below it is untouched. Re-projecting here would
    // rebuild the simulation on a change that did not move it, and a fling that
    // rebuilds itself is the destination-chasing `PanelConfig.resnapWindow`
    // bounds on the model's side.
  }

  /// Stops the ticker and releases it.
  ///
  /// Called by `ScrollPosition.beginActivity` when anything replaces this — a
  /// finger landing, a `goIdle`, the model parking the panel. A `Ticker` that
  /// outlives its activity is the leak, and in debug it also asserts.
  ///
  /// Written rather than deferred, for `PanelModel.dispose`'s reason: there is
  /// no decision in it, only an order, and the order is forced.
  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  String toString() => 'FusedBallisticActivity($simulation)';
}
