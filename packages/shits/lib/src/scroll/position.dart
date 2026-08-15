/// The owned `ScrollPosition`, and the controller that installs it.
///
/// Owning the position rather than observing it is the largest call in
/// DESIGN.md, and the reason is one sentence: **a user-supplied `physics:`
/// cannot shadow arbitration that lives in `drag` and `goBallistic`.**
/// `scrollable.dart:622` applies the widget's own physics *outermost* and
/// `scroll_physics.dart:710-716` does not delegate `applyPhysicsToUserOffset` to
/// its parent, so `ListView(physics: BouncingScrollPhysics())` silently disables
/// any split that lives in physics. `capture_test.dart` already pins that a bare
/// list picks this controller up on every platform; this file is what the
/// controller then does.
library;

import 'package:flutter/gestures.dart';
// One enum, and it is the only thing in this file that `widgets.dart` cannot
// name: `ScrollDirection` lives in `rendering/viewport_offset.dart` and
// `widgets.dart` re-exports `rendering.dart` for `TextSelectionHandleType`
// alone. `updateUserScrollDirection` — a `@protected` member of the class this
// one extends — takes one, so a subclass cannot publish a scroll direction
// without it.
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

import '../geometry/units.dart';
import '../model/activity.dart';
import 'activity.dart';
import 'link.dart';

/// The `ScrollController` a panel publishes through `PrimaryScrollController`.
///
/// Public, and that is deliberate: it is half of what the escape error tells an
/// author to reach for. A list that genuinely needs its own controller keeps its
/// place in the handoff by being handed one of these instead of a plain
/// `ScrollController`, and that is a two-word fix rather than a redesign.
///
/// `PrimaryScrollController.shouldInherit` uses
/// `findAncestorWidgetOfExactType<PrimaryScrollController>()`
/// (`primary_scroll_controller.dart:125-137`), an **exact** type match, so the
/// widget published above is always the framework's `PrimaryScrollController`
/// and never a subclass — a subclass would be invisible to the lookup and the
/// whole capture claim would silently become false. This is a `ScrollController`
/// subclass, which is a different question and is fine.
final class PanelScrollController extends ScrollController {
  /// Creates a controller whose positions arbitrate through [link].
  PanelScrollController({required this.link, super.debugLabel});

  /// The arbiter every position this controller creates will hold.
  final PanelScrollLink link;

  /// Creates a [PanelScrollPosition], wrapping [physics] so a short list still
  /// drags.
  ///
  /// **The wrap is not an optimisation.** `ScrollPositionWithSingleContext`
  /// calls `context.setCanDrag(physics.shouldAcceptUserOffset(this))` from
  /// `applyNewDimensions`, and the default physics answers false for a list
  /// whose content is shorter than its viewport. `setCanDrag(false)` removes the
  /// drag recogniser outright, so the panel never sees the gesture at all — a
  /// sheet with three short rows in it would be undraggable from its content,
  /// which is the failure that reads as "the sheet only works when the list is
  /// long".
  ///
  /// Already-`AlwaysScrollableScrollPhysics` physics is passed through rather
  /// than wrapped again, so that an author who asked for it explicitly does not
  /// get two of them and the `parent` chain stays the length they wrote.
  @override
  PanelScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => PanelScrollPosition(
    link: link,
    physics: physics is AlwaysScrollableScrollPhysics
        ? physics
        : AlwaysScrollableScrollPhysics(parent: physics),
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );

  /// Registers [position] with [link] as well as with this controller, and
  /// points it at [link].
  ///
  /// The link's registry is what `absorb` and the escape detector compare
  /// against, and it is on the link rather than here because the link outlives
  /// any one controller — a placement change rebuilds the widget that owns the
  /// controller and not the panel.
  ///
  /// **The binding is refreshed here and not only in `absorb`, because a
  /// controller swap does not replace the position.**
  /// `PanelScrollAttachment.didUpdateWidget` builds a new controller carrying
  /// the new link whenever the link is swapped — a shape it explicitly supports
  /// — and `Scrollable.didUpdateWidget` then detaches the position from the old
  /// controller and attaches it to this one (`scrollable.dart:711-724`) without
  /// creating a new one, because `_shouldUpdatePosition` compares the physics
  /// and the controller's `runtimeType` and both are unchanged. So `absorb`
  /// never runs, and a position whose link were repointed only there would keep
  /// arbitrating for the panel it used to be in: the finger would drag the sheet
  /// that is no longer on screen while the visible one stood still, and the
  /// registry and the position would disagree about which panel the list belongs
  /// to.
  ///
  /// **And the panel it is leaving is told**, because a list can move between
  /// panels with a finger already on it: `didUpdateWidget` detaches and attaches
  /// *before* `_shouldUpdatePosition` decides anything, so the position that
  /// arrives here may still be driving a `ScrollDragActivity` on the previous
  /// link's model. Nothing else will ever end it — `absorb` looks at the new
  /// link, and so does [PanelScrollPosition.dispose] once this line has run —
  /// and the panel left behind would answer `LayoutCorrection.freeze` and report
  /// `isUserDriven` for the rest of the session. Measured without it: panel A
  /// parked at 529.68 holding a drag, through the release and through
  /// `pumpAndSettle`.
  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    if (position is PanelScrollPosition && !identical(position.link, link)) {
      // The panel this list is leaving, before it stops being reachable from
      // here. `releaseDriver` is a no-op unless the old model really is holding
      // something of this position's.
      position.link.releaseDriver(position);
      position.link = link;
    }
    link.register(position);
  }

  /// Unregisters [position] from [link].
  ///
  /// A link still holding a detached position is the use-after-free `absorb`
  /// exists to prevent, one layer up: Flutter replaces a position outright when
  /// the physics or the controller `runtimeType` changes
  /// (`scrollable.dart:686-698`), and the old one is disposed immediately after.
  @override
  void detach(ScrollPosition position) {
    super.detach(position);
    link.unregister(position);
  }
}

/// The `ScrollPosition` a panel owns, with the split in six overrides.
///
/// **DESIGN.md §3.1 says four, and names them: `hold`, `drag`, `goBallistic`,
/// `goIdle`, with `absorb` alongside. Two more are needed and both are load
/// bearing.**
///
/// **[applyUserOffset], and the split lives there rather than in [drag].** The
/// document's reason for putting the split in `drag` is that a user-supplied
/// `physics:` must not be able to shadow it, and a method on the *position*
/// satisfies that in full — `ScrollPhysics` is a different object. What `drag`
/// cannot do is see a delta the framework has finished preparing:
/// `ScrollDragController.update` reverses the raw pointer delta for
/// `axisDirectionIsReversed` (`scroll_activity.dart:321`) and then runs it
/// through `_adjustForScrollStartThreshold`, iOS's motion-start threshold. A
/// split above that would have to reimplement both, and the second one is 40
/// lines of timestamp bookkeeping whose only observable effect is that a list
/// does not creep when a finger rests on it.
///
/// **[pointerScroll], because a wheel is not a drag.** This is the hole
/// underneath DESIGN.md's desktop argument. Passing every platform to
/// `automaticallyInheritForPlatforms` gets the controller *installed* on macOS,
/// Windows and Linux — which is what `capture_test.dart` measures — but the
/// input a desktop actually delivers is a pointer-scroll signal, and
/// `ScrollPositionWithSingleContext.pointerScroll` never reaches
/// [applyUserOffset]: it clamps to `[minScrollExtent, maxScrollExtent]` and
/// calls `forcePixels` (`:219-234`). So on a trackpad, with the capture working
/// perfectly, a list at its top absorbs the whole gesture — `targetPixels ==
/// pixels`, nothing happens — and the panel cannot be opened or closed by
/// scrolling at all. Fixing the inheritance and not this would make the desktop
/// *look* handled while the one gesture a desktop user has still did nothing.
///
/// Everything else in `ScrollPositionWithSingleContext` flows through the
/// `ScrollActivity` these begin.
///
/// **Implements `PanelScrollDriver` for free.** The model's narrow view of a
/// scrollable is `pixels`, `minScrollExtent` and `maxScrollExtent`, and
/// `ScrollPosition` has all three. So the model layer, which cannot name
/// `ScrollPosition`, holds this object through an interface it can name, and
/// there is no adapter to keep in sync.
final class PanelScrollPosition extends ScrollPositionWithSingleContext
    implements PanelScrollDriver {
  /// Creates a position that arbitrates through [link].
  PanelScrollPosition({
    required this.link,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// The arbiter.
  ///
  /// Mutable, because `absorb` hands it across from a position being replaced —
  /// and a link binding that survived on a disposed position is the
  /// use-after-free that `absorb` exists for.
  PanelScrollLink link;

  /// Stops whatever the panel and the list are doing, without starting anything.
  ///
  /// A hold is a finger down that has not moved yet, and on the panel side that
  /// is **a drag with no deltas**: it answers `LayoutCorrection.freeze`, reports
  /// `isUserDriven`, ticks nothing and moves nothing. So this installs a
  /// `ScrollDragActivity` on the model and returns the framework's
  /// `HoldScrollActivity` for the list.
  ///
  /// It is emphatically **not** `PanelModel.goIdle`. `goIdle` installs
  /// `LayoutCorrection.hold`, which resolves to the target detent's height on the
  /// very next layout pass — so a finger landing on a panel mid-settle at 500pt
  /// would teleport it to 469.68 without animation, on the first frame after the
  /// touch. The measured shape of that mistake is why the drag activity is the
  /// right one: `freeze` is the correction that means "the finger owns this".
  ///
  /// DESIGN.md §1.2 wants a distinct `ScrollHoldActivity` leaf here. It cannot be
  /// added from this layer — `ScrollDrivenActivity` is `sealed` into
  /// `model/activity.dart` — and `test/model/correction_test.dart`'s own rule
  /// would merge it away if it could: two leaves with identical corrections and
  /// identical tick behaviour are one leaf. See `activity.dart`.
  ///
  /// The release path needs nothing extra. `HoldScrollActivity.cancel` calls
  /// `delegate.goBallistic(0)`, which is [goBallistic] below, which finds a
  /// `ScrollDragActivity` on the model and ends it at zero — a settle to the
  /// nearest detent, through the same code a real release takes.
  @override
  ScrollHoldController hold(VoidCallback holdCancelCallback) {
    link.model.beginActivity(
      ScrollDragActivity(position: this, from: link.model.extent),
    );
    return super.hold(holdCancelCallback);
  }

  /// Begins a split drag: a `ScrollDragActivity` on the model and a
  /// `ScrollDragController` for the content, paired by a `PanelDrag`.
  ///
  /// The `Drag` returned to the gesture recogniser is ours, so every delta is
  /// arbitrated before either half sees it. The framework's own drag is kept
  /// underneath rather than reimplemented, because it carries velocity tracking,
  /// `physics.carriedMomentum` off a held previous velocity, and the iOS
  /// motion-start threshold — three behaviours that are invisible until they are
  /// missing.
  ///
  /// The model activity is seeded `from: model.extent`, which is where the
  /// finger actually landed rather than wherever the previous gesture's
  /// overshoot left the accumulated position.
  @override
  Drag drag(DragStartDetails details, VoidCallback dragCancelCallback) {
    // The framework's own drag is kept underneath rather than reimplemented: it
    // carries velocity tracking, `physics.carriedMomentum` off the held previous
    // velocity, and iOS's motion-start threshold — three behaviours that are
    // invisible until they are missing, and two of which are written against
    // private state on `ScrollPositionWithSingleContext` that a reimplementation
    // here could not read.
    //
    // The cast is the price of that. `super.drag` is declared to return `Drag`
    // and returns the `ScrollDragController` it also stores as `_currentDrag`,
    // which is what makes `absorb` and the framework's own disposal keep
    // working; a Flutter that changed the concrete type would fail here rather
    // than silently stop arbitrating.
    final content =
        super.drag(details, dragCancelCallback) as ScrollDragController;
    // Seeded at where the finger actually landed, rather than at wherever the
    // previous gesture's overshoot left the accumulated position.
    final panel = ScrollDragActivity(position: this, from: link.model.extent);
    link.model.beginActivity(panel);
    return _panelDrag = PanelDrag(
      position: this,
      panel: panel,
      content: content,
    );
  }

  /// The split drag this position handed to the gesture recogniser, or null.
  ///
  /// The mirror of `ScrollPositionWithSingleContext._currentDrag`, and it exists
  /// because that field is private: [absorb] has to hand a live gesture across
  /// to the position replacing this one, and the framework only does half the
  /// job. It moves the `ScrollDragController` over and calls `updateDelegate`
  /// on it (`:100-103`), so the content half of a swapped gesture keeps working;
  /// the panel half is a `ScrollDragActivity` whose `position` is `final` in a
  /// sealed hierarchy, so it can only be *replaced* — and the `PanelDrag` the
  /// recogniser is still holding has to be told, which is what this field is
  /// for. See `PanelDrag.rebind` for the state it prevents.
  PanelDrag? _panelDrag;

  /// Splits one prepared drag delta and gives each half to its owner.
  ///
  /// **This is the arbiter's one call site for a gesture.** [delta] is in drag
  /// space — positive lowers `pixels` — and has already been reversed for the
  /// axis direction and adjusted for the iOS motion-start threshold by
  /// `ScrollDragController`, which is exactly why the split is here and not in
  /// [drag].
  ///
  /// `link.split` decides; this applies. The panel's share goes to the
  /// `ScrollDragActivity` on the model, and the content's share goes to
  /// `super.applyUserOffset`, so `setPixels`, `applyBoundaryConditions`,
  /// `didOverscroll` and every `ScrollUpdateNotification` happen exactly as they
  /// would outside a panel. That last part is the whole of the pull-to-refresh
  /// story: a `RefreshIndicator` sees an `OverscrollNotification` because the
  /// list really did overscroll, not because anything simulated one for it.
  ///
  /// A `super` call with a zero content share is still made, so
  /// `updateUserScrollDirection` keeps tracking and a `Scrollbar` does not
  /// freeze mid-gesture while the panel is the thing moving.
  ///
  /// **A panel share this position is not allowed to write goes to the content
  /// instead of nowhere.** The panel's half is only written into a gesture this
  /// position started; the content's half was computed as *the leftover after
  /// the panel took its cut*, so dropping the first without adding it to the
  /// second loses the pixels outright — and `link.split` promises the two shares
  /// sum to the delta exactly, which is a promise about the arbiter's arithmetic
  /// that its one caller can still break. Measured, before this: a 30pt drag,
  /// then `goIdle` from a button, then 30pt more moved **neither** the panel nor
  /// the list, and stayed dead until the finger lifted.
  @override
  void applyUserOffset(double delta) {
    final split = link.split(link.extentDeltaOfDrag(delta), this);
    // The panel's share, but only into a gesture this position started. A
    // programmatic `animateTo` mid-drag replaces the model's activity, and
    // writing through the one it replaced would move a panel that a spring is
    // already moving.
    final gesture = switch (link.model.activity) {
      final ScrollDragActivity ours when identical(ours.position, this) => ours,
      _ => null,
    };
    gesture?.update(split.panel);
    // The whole delta when the panel's share was refused: the finger moved, and
    // the content is the only thing left that this position can move with it.
    final content = link.dragDeltaOfExtent(
      gesture == null ? split.total : split.content,
    );
    if (content != 0.0) {
      // `super` runs `setPixels`, so `applyBoundaryConditions`, `didOverscroll`
      // and every `ScrollUpdateNotification` happen exactly as they would
      // outside a panel. That is the whole of the pull-to-refresh story: a
      // `RefreshIndicator` sees an `OverscrollNotification` because the list
      // really did overscroll, not because anything simulated one for it.
      super.applyUserOffset(content);
      return;
    }
    // A zero share cannot go through `super`: `BouncingScrollPhysics.applyPhysicsToUserOffset`
    // opens with `assert(offset != 0.0)` (`scroll_physics.dart:711`), which is
    // reachable here and nowhere in the framework, because nothing else hands a
    // position a delta that another consumer has already taken all of. The
    // direction still has to be published — it is the same finger, and a
    // `Scrollbar` that stopped hearing about it would fade out mid-gesture while
    // the panel is the thing moving — so this is `super`'s first line without
    // its second.
    updateUserScrollDirection(
      delta > 0.0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
  }

  /// Splits a wheel or trackpad scroll, which [applyUserOffset] never sees.
  ///
  /// `ScrollPositionWithSingleContext.pointerScroll` is a separate path with a
  /// separate sign convention — its [delta] is added to `pixels`
  /// (`:219-222`), where `applyUserOffset`'s is subtracted — and it clamps to
  /// the content's own extents before doing anything. Left alone, a trackpad
  /// scroll at the top of a list inside a panel is silently a no-op, on the one
  /// platform family DESIGN.md §3's desktop argument is entirely about.
  ///
  /// So this arbitrates first, through the same `link.split`, and hands the
  /// content's share to `super.pointerScroll`. There is no drag activity to put
  /// the panel's share into — a wheel has no `Drag` and no lifetime — so the
  /// panel is moved and left to settle: the discrete gesture ends the moment it
  /// is delivered, which is also why `pointerScroll` calls `goBallistic(0)` on
  /// its own way out.
  ///
  /// **The sign is the thing to be careful about**, and it is why the link names
  /// `extentDeltaOfScroll` and `extentDeltaOfDrag` separately rather than
  /// exposing one conversion the caller has to remember to negate.
  @override
  void pointerScroll(double delta) {
    // The framework's own early-out, kept because `super` would take it anyway
    // and splitting a zero would install a gesture on the model that the
    // trailing `goBallistic(0)` immediately ends.
    if (delta == 0.0) {
      super.pointerScroll(delta);
      return;
    }
    final split = link.split(link.extentDeltaOfScroll(delta), this);
    if (split.panel != 0) {
      // A wheel has no `Drag` and no lifetime, so the panel's share goes into a
      // gesture that lasts exactly as long as the event: `super.pointerScroll`
      // ends with `goBallistic(0)`, which reaches [goIdle] below and settles the
      // panel at the nearest detent. That is what "the discrete gesture ends the
      // moment it is delivered" costs — a notch that does not reach the midpoint
      // between two detents springs back, the way a half-swiped page does.
      final gesture = ScrollDragActivity(
        position: this,
        from: link.model.extent,
      );
      link.model.beginActivity(gesture);
      gesture.update(split.panel);
    }
    super.pointerScroll(link.scrollDeltaOfExtent(split.content));
  }

  /// Releases both halves as **one** fused ballistic.
  ///
  /// Four paths, told apart by what the model is holding and where the two
  /// halves are, rather than by a flag:
  ///
  /// - **Not our release.** Anything but a `ScrollBallisticActivity` of this
  ///   position on the model — the model settled the panel itself because the
  ///   release was too small to fling, another list's finger owns it, or nothing
  ///   panel-driven is running — so `super.goBallistic` and the list alone.
  /// - **The policy refuses the panel this throw.** `super.goBallistic` for the
  ///   list, and the panel is settled at *zero*: it keeps none of the momentum
  ///   the arbitration would not have given it as a drag.
  /// - **Off the rail**, where the fused coordinate cannot describe the pair.
  ///   `super.goBallistic` for the list and the panel's own settle at the speed
  ///   the drag ended at, which is two simulations for one lift and is the right
  ///   answer, because off the rail they are two independent axes.
  /// - **Otherwise**, the fused axis and the fused simulation from [velocity],
  ///   in one `FusedBallisticActivity` that writes both halves.
  ///
  /// Because this position is owned there is **no `goIdle()` stomp to dodge**.
  /// `ScrollPositionWithSingleContext.goBallistic` calls `goIdle()` whenever
  /// `physics.createBallisticSimulation` returns null
  /// (`scroll_position_with_single_context.dart:149-157`), which is what forces
  /// `smooth_sheets` into a microtask and a `_SettledSimulation` swap. Here the
  /// activity is installed directly and that whole apparatus is absent.
  ///
  /// [velocity] is in scroll space — positive when `pixels` rises — and is
  /// converted through `PanelAnchor` exactly once, inside the link.
  @override
  void goBallistic(double velocity) {
    final panel = link.model.activity;
    if (panel is! ScrollBallisticActivity || !identical(panel.position, this)) {
      super.goBallistic(velocity);
      return;
    }
    final extentDelta = link.extentDeltaOfScroll(velocity);
    // Whether the panel and the list are one rail right now, which decides both
    // of the questions below: what the release *is*, and where the policy has
    // to be asked about it.
    final fused = link.isOnFusedAxis(this);
    // The release the arbitration already refused, and the third path DESIGN.md
    // §3.3 does not name. `split` enforces `PanelScrollPolicy` and
    // `PanelRefreshPolicy` on every delta of the drag; a release that consulted
    // neither would move the panel with momentum the split declined a frame
    // earlier — `scrollsFirst` says the panel is moved only by its handle, its
    // background or code, and a fling closed the sheet anyway.
    //
    // **Where the question is asked is the whole of it.** On the rail the
    // release reaches the panel either now (the content is at its start) or at
    // the seam (it is not, so the fling must run the list out first), and
    // `panelMayTakeRelease` is that distinction. Off the rail there is no seam
    // to cross: the panel is somewhere in its own travel and the throw would
    // move it from exactly there, so the state to ask about is this one.
    if (!(fused
        ? link.panelMayTakeRelease(extentDelta, this)
        : link.panelMayTake(extentDelta, this))) {
      link.model.goBallistic(ExtentVelocity.zero);
      super.goBallistic(velocity);
      return;
    }
    // A release from off the rail, which is the other thing a fused coordinate
    // cannot describe — see `PanelScrollLink.isOnFusedAxis` for which pairs it
    // can and what the sum does with the ones it cannot.
    //
    // Off the rail the two are not one fling anyway: each has its own way back
    // — the panel through `snapTarget` and the rubber band, the list through
    // `BouncingScrollSimulation`, which is the only thing that can spring an
    // overscroll back and which a fused simulation has no way to express.
    if (!fused) {
      // At the speed the drag ended at, not at zero: the panel may be
      // mid-overdrag, and a spring seeded from rest there is the discontinuity
      // this whole layer is built to avoid.
      link.model.goBallistic(panel.velocity);
      super.goBallistic(velocity);
      return;
    }
    beginActivity(
      FusedBallisticActivity(
        delegate: this,
        simulation: link.flingFor(ScrollVelocity(velocity), this),
        panel: panel,
        vsync: context.vsync,
      ),
    );
  }

  /// Ends the handoff: the list is idle, so the panel stops being scroll-driven.
  ///
  /// `super.goIdle()` for the list, and the panel is released to a self-driven
  /// settle at zero velocity if it is still holding one of our activities. A
  /// settle of zero from a detent is an *arrival* — `PanelModel._settleAt`
  /// refuses to build a spring with nothing to do and parks instead — so an
  /// already-parked panel is not restarted by an idling list, and one left
  /// between detents by a fling that was cut short is put on the nearest one.
  ///
  /// The alternative, leaving a `ScrollDrivenActivity` installed with nothing
  /// driving it, is the terminal state `ScrollBallisticActivity.tick`'s doc
  /// describes: a panel that answers `freeze` to every layout change afterwards
  /// and can no longer follow a rotation or a keyboard.
  @override
  void goIdle() {
    super.goIdle();
    final panel = link.model.activity;
    if (panel is ScrollDrivenActivity && identical(panel.position, this)) {
      link.model.goBallistic(ExtentVelocity.zero);
    }
  }

  /// Takes [other]'s state, and its binding to the panel.
  ///
  /// Flutter replaces a position outright when the physics or controller
  /// `runtimeType` changes (`scrollable.dart:686-698`), disposing the old one
  /// immediately. Everything the panel holds that points at the old position has
  /// to be repointed here, and one thing cannot be: `ScrollDrivenActivity.position`
  /// is `final` in a sealed hierarchy this layer does not own.
  ///
  /// So the binding is repointed by **replacing the model activity**, not by
  /// mutating it:
  ///
  /// - A `ScrollDragActivity` becomes a fresh one on this position, seeded at
  ///   the panel's current extent and then `rebase`d onto it. `rebase` runs the
  ///   rubber band backwards, so an overdrag in progress is recovered exactly
  ///   rather than lost — which is the one thing a naive re-seed would drop, and
  ///   `PanelDragMechanics.rawExtent`'s doc names `RubberBand.inverse` as the way
  ///   to do it.
  /// - A `ScrollBallisticActivity` is handed to the panel's own settle at its
  ///   current velocity. A fused fling cannot survive its position being swapped
  ///   — half its axis just ceased to exist — and continuing on the panel alone
  ///   at the speed it was going is the closest thing to not noticing.
  ///
  /// And the `Drag` the gesture recogniser is holding is repointed with it. The
  /// framework moves the content's `ScrollDragController` across and calls
  /// `updateDelegate` on it (`:100-103`), so that half of a swapped gesture has
  /// always kept working; [_panelDrag] is the other half, and `PanelDrag.rebind`
  /// names the terminal state a stale one produces.
  ///
  /// `super.absorb` first, because `ScrollPositionWithSingleContext.absorb`
  /// re-delegates the running activity and moves `_currentDrag` across, and both
  /// must have happened before the model is told anything.
  @override
  void absorb(ScrollPosition other) {
    // First, because `ScrollPositionWithSingleContext.absorb` re-delegates the
    // running activity and moves `_currentDrag` across, and both must have
    // happened before the model is told anything.
    super.absorb(other);
    if (other is! PanelScrollPosition) return;
    // **Belt and braces, and said so rather than implied**, in the same shape
    // and for the same reason as `replacement.rebase` below. This is a no-op
    // today: [PanelScrollController.attach] refreshes `other`'s binding before
    // `_updatePosition` ever builds this position, and this position was
    // constructed by the same controller — so `other.link` is already `link` at
    // every reachable call. Deleting it therefore leaves the suite green, which
    // is exactly why it is here: `absorb` taking *everything* across is a
    // property of `absorb`, not of an ordering two framework methods happen to
    // have today.
    link = other.link;
    // The `Drag` the recogniser is holding survives the swap — it is the object
    // `other.drag` returned, and nothing tells the recogniser otherwise — so it
    // comes across here beside the framework's own `_currentDrag`.
    _panelDrag = other._panelDrag;
    other._panelDrag = null;
    final model = link.model;
    switch (model.activity) {
      // `ScrollDrivenActivity.position` is final in a sealed hierarchy this
      // layer does not own, so the binding is repointed by replacing the
      // activity rather than by mutating it.
      case final ScrollDragActivity gesture
          when identical(gesture.position, other):
        final replacement = ScrollDragActivity(
          position: this,
          from: model.extent,
        );
        model.beginActivity(replacement);
        // And the live `PanelDrag` is told which activity is now the panel's
        // half of its gesture. Without this the release ends the one
        // `beginActivity` has just disposed, which installs a fling on the model
        // bound to `other` — a position `goBallistic` refuses to build a fused
        // activity for, so nothing ever ticks it and the panel is frozen
        // wherever the finger left it. See `PanelDrag.rebind`.
        _panelDrag?.rebind(position: this, panel: replacement);
        // Seeding from the extent alone would lose an overdrag in progress: the
        // extent is what the band is *showing*, and the gesture accumulates what
        // the finger is *at*. `rebase` runs the band backwards, which recovers
        // it exactly — the one thing a naive re-seed drops, and the reason
        // `RubberBand.inverse` exists.
        //
        // **Belt and braces, and said so rather than implied.** A position is
        // only ever replaced from inside a build, so a layout pass follows
        // before anything reads this gesture again — and `PanelModel.applyLayout`
        // rebases it there too, because a drag answers `LayoutCorrection.freeze`.
        // Deleting this line leaves `position_test.dart` green for that reason,
        // which is exactly why it is here: `absorb` finishing its own job is a
        // property of `absorb`, not of what the frame does next.
        replacement.rebase(model.extent);
      case final ScrollBallisticActivity fling
          when identical(fling.position, other):
        // A fused fling cannot survive its position being swapped — half its
        // axis has just ceased to exist — and continuing on the panel alone at
        // the speed it was going is the closest thing to not noticing.
        model.goBallistic(fling.velocity);
      case _:
        break;
    }
  }

  /// Hands the panel back before this position stops existing.
  ///
  /// A captured list removed from the tree mid-drag — a route popped, a page
  /// swiped away, a `ListView` rebuilt under a new `Key` — leaves the model
  /// holding a `ScrollDragActivity` with no finger and no position behind it.
  /// That is the terminal state `ScrollBallisticActivity.tick`'s doc and
  /// `PanelScrollLink.dispose` both name: `freeze` for ever, so the panel can no
  /// longer follow a rotation or a keyboard, and `isUserDriven` for ever, so
  /// `updateConfig` will never re-snap it and a route will never begin its exit.
  ///
  /// **Here rather than in `PanelScrollController.detach`, and the order is the
  /// reason.** `scrollable.dart:617-636` detaches the old position *before*
  /// building the one that absorbs it, so a `detach` that ended the gesture
  /// would end the drag Flutter is in the middle of handing on: [absorb] would
  /// find a settle where the drag used to be, and a physics change under a live
  /// finger would stop the panel dead. Disposal is the seam that means *gone* —
  /// `_updatePosition` schedules it in a microtask, after `absorb` has already
  /// replaced the model's activity with one bound to the new position, so the
  /// identity test below is false exactly when something took over.
  ///
  /// A settle of zero from a detent is an arrival — `PanelModel._settleAt`
  /// refuses to build a spring with nothing to do — so a panel that was already
  /// parked is not animated by a list going away.
  @override
  void dispose() {
    link.releaseDriver(this);
    _panelDrag = null;
    super.dispose();
  }

  /// Adds the panel's side of the handoff to `ScrollPosition.toString()`.
  ///
  /// `ScrollPosition` describes itself with `debugFillDescription` and a list of
  /// strings rather than with `debugFillProperties` and a
  /// `DiagnosticPropertiesBuilder`, so this is the shape available here.
  ///
  /// Written rather than deferred, for `RenderPanelViewport.debugFillProperties`'
  /// reason: a diagnostics method that throws turns a dump — which is what
  /// someone reaches for when something has *already* failed — into a second,
  /// unrelated failure on top of the first. And "who has the delta" is the first
  /// question anyone asks of this class, so the answer belongs in the one string
  /// every scroll notification already prints.
  @override
  void debugFillDescription(List<String> description) {
    super.debugFillDescription(description);
    description
      ..add('panel: ${link.model.extent.px}')
      ..add('panelActivity: ${link.model.activity.runtimeType}')
      ..add('scrollPolicy: ${link.scrollPolicy.name}')
      ..add('refreshPolicy: ${link.refreshPolicy.name}');
  }
}
