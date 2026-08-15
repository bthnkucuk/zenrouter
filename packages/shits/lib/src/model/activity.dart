import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:meta/meta.dart';

import '../geometry/detent.dart';
import '../geometry/detent_set.dart';
import '../geometry/units.dart';
import '../physics/motion.dart';
import '../physics/projection.dart';
import '../physics/rubber_band.dart';
import 'correction.dart';
import 'panel_model.dart';

/// How close to its destination a settle has to get before it stops, in logical
/// pixels, when nothing has told it what a physical pixel is worth.
///
/// Half a physical pixel is the only threshold that means anything — it is what
/// [Extent.isCloseTo] compares at, and below it two extents are the same row of
/// pixels — but an activity is built *before* it is installed, which is how a
/// fling reads, so it cannot always reach a [PanelModel] to ask for a device
/// pixel ratio. [PanelModel] passes the real one; this is what a settle built by
/// hand gets, and it is 3x because that is the finest display in common use and
/// erring fine costs a few frames of tail that nobody can see, where erring
/// coarse stops the panel somewhere visibly short.
///
/// The default `Tolerance` is not usable here: it is calibrated for a 0..1 route
/// animation, and over a span in logical pixels it settles about a thousand
/// times tighter than the screen can show.
const double kSettleTolerance = 0.5 / 3.0;

/// What a panel is currently doing, and therefore what a layout change means to
/// it.
///
/// The hierarchy is split in two — [SelfDrivenActivity] and
/// [ScrollDrivenActivity] — and the split is the point. `smooth_sheets` has one
/// activity type carrying a **nullable** "who is driving me" and switches on it
/// at every use (`lib/src/scrollable.dart:147-152`), so every scroll-aware code
/// path is written twice: once for the case that cannot happen and once for the
/// case that matters. Here a scroll-driven activity's [ScrollDrivenActivity.position]
/// is non-nullable, and an activity that is not scroll-driven has no field to
/// read.
///
/// This slice ships five leaves, not nine. `Ballistic` is folded into
/// [SettlingPanelActivity] — a self-driven fling is a spring toward a detent
/// that was already chosen at release, which is exactly what a settle is — and
/// `ScrollHold` waits for the scroll layer, which is what constructs it.
///
/// An activity is a small mutable object with a lifetime: constructed, attached
/// to a model by `PanelModel.beginActivity`, ticked while it wants frames, then
/// [dispose]d when the next one replaces it.
sealed class PanelActivity {
  /// Allows the leaves to declare their own constructors.
  PanelActivity();

  /// The model this activity is driving.
  ///
  /// Assigned by `PanelModel.beginActivity`, not by the constructor, so that an
  /// activity can be built and inspected before it is installed — which is how
  /// a fling reads: decide the settle, build it, then hand it over. Reading this
  /// before installation is a programmer error and throws.
  PanelModel get owner =>
      _owner ??
      (throw StateError(
        'This $runtimeType has not been installed on a PanelModel yet. An '
        'activity is built, inspected and only then handed to '
        'PanelModel.beginActivity, which is what binds it — so reading its '
        'owner in between is reading a binding that has not happened.',
      ));

  /// The model, or null while this activity is still being built.
  ///
  /// The leaves that move the panel read this rather than [owner]: ticking an
  /// activity that was never installed advances its own clock and moves nothing,
  /// because there is nothing to move, and that is what lets a test inspect a
  /// settle's clock without standing a model up around it.
  PanelModel? _owner;

  /// Binds this activity to [owner]. Called once, by `PanelModel.beginActivity`.
  @internal
  void attach(PanelModel owner) => _owner = owner;

  /// How fast the panel is moving right now, in px/s, positive when growing.
  ///
  /// Live rather than seeded: a settle reports what its simulation is doing at
  /// this instant, so a correction that re-projects from it re-projects from the
  /// truth. An activity that is not moving the panel itself reports
  /// [ExtentVelocity.zero] — including a drag, whose speed is the gesture
  /// recogniser's estimate and arrives only when the finger leaves.
  ExtentVelocity get velocity;

  /// What a layout change means to this activity.
  ///
  /// **Pure, cheap and silent.** It is read inside a layout pass, twice, and the
  /// model asserts that reading it twice gives the same answer and fires no
  /// notification. It may read the clock this activity already keeps; it may not
  /// advance it.
  LayoutCorrection get onLayoutChanged;

  /// Whether a finger is on the panel right now.
  ///
  /// Not "whether the panel is moving" — a settle moves and is not user-driven.
  /// The consumers are the ones that must not act over the top of a gesture: a
  /// route that would otherwise begin its exit, a config change that would
  /// otherwise snap.
  bool get isUserDriven;

  /// Whether this activity needs frames.
  ///
  /// The model layer owns no ticker — it imports no binding, which is what keeps
  /// every test under `test/model/` device-free — so the widget above it drives
  /// [tick] and reads this to know when to stop. False for everything a finger
  /// moves, true for everything a simulation moves.
  bool get isTicking;

  /// Advances this activity by [delta], the time since the previous frame.
  ///
  /// A frame delta rather than a total elapsed, so that an activity installed
  /// mid-flight starts its own clock at zero without the driver having to reset
  /// anything. `Duration` arithmetic is exact integer microseconds, so
  /// accumulating deltas does not drift the way summing seconds would.
  ///
  /// A non-ticking activity ignores it. A ticking one samples its simulation,
  /// writes the extent through `PanelModel.applyExtent`, and asks the model to
  /// go idle once it is done.
  void tick(Duration delta);

  /// Whether [dispose] has been called on this activity.
  ///
  /// The observable half of disposal, and the reason it is here rather than
  /// nowhere: every leaf currently *holds* nothing, so a [dispose] that was
  /// never called would look exactly like one that was, and the two calls that
  /// make the lifetime a lifetime — `PanelModel.beginActivity` on the outgoing
  /// activity, `PanelModel.dispose` on the current one — could both be deleted
  /// without anything noticing. It is the seam the scroll layer's `absorb` lands
  /// on, and a seam nothing can see is a seam nobody can keep.
  bool get isDisposed => _disposed;
  bool _disposed = false;

  /// Releases whatever this activity holds.
  ///
  /// Called by `PanelModel.beginActivity` on the outgoing activity and by
  /// `PanelModel.dispose` on the current one, so exactly one call happens per
  /// activity. The scroll-driven leaves unbind their position here; a position
  /// still bound to a disposed activity is the use-after-free `absorb` exists to
  /// prevent.
  ///
  /// A leaf that holds nothing does not override this at all — the bookkeeping
  /// [isDisposed] needs is the whole body — and one that does must call
  /// `super.dispose()`.
  @mustCallSuper
  void dispose() => _disposed = true;
}

/// A panel moving under its own gestures and its own springs, with no scrollable
/// involved.
sealed class SelfDrivenActivity extends PanelActivity {}

/// Parked at a detent, doing nothing until something asks it to.
///
/// "Parked at a detent" and not "parked at a height": the whole reason this
/// carries a [Detent] rather than an [Extent] is that a rotation or a keyboard
/// changes what the detent means, and an idle panel is supposed to follow it.
final class IdlePanelActivity extends SelfDrivenActivity {
  /// Parks the panel at [target].
  IdlePanelActivity({required this.target});

  /// The detent the panel is resting at.
  final Detent target;

  /// [ExtentVelocity.zero] — nothing is moving.
  @override
  ExtentVelocity get velocity => ExtentVelocity.zero;

  /// [LayoutCorrection.hold] of [target].
  @override
  LayoutCorrection get onLayoutChanged => LayoutCorrection.hold(target);

  /// False.
  @override
  bool get isUserDriven => false;

  /// False.
  @override
  bool get isTicking => false;

  /// Ignores [delta].
  @override
  void tick(Duration delta) {}
}

// ============================================================================
// The drag arithmetic, written once.
//
// `DragPanelActivity` and `ScrollDragActivity` do the same thing to the same
// numbers and are still two classes, because merging them needs a nullable
// position and that is the defect this hierarchy is shaped around. What they
// must not have is two copies of the arithmetic — a band applied one way on one
// branch and another way on the other is a bug that only shows up as "the sheet
// feels different when you drag the list", which nobody reports as a bug.
// ============================================================================

/// The band a panel overdrags against, built from what the model measured.
///
/// Normalised to the viewport rather than to the panel, so the resistance at
/// 100pt of overdrag is the same at every detent, and taking the coefficient
/// from the config rather than from `RubberBand`'s own default is the only way
/// an author can reach it — the band is built per gesture from a viewport the
/// model measures, so there is no call site to pass one at.
RubberBand _bandOf(PanelModel owner) => RubberBand(
  viewport: owner.layout.baseline.viewportSpan,
  c: owner.config.bandResistance,
);

/// How far past the nearest end of the travel [raw] has pulled, as a magnitude.
///
/// Zero inside the travel, and a magnitude at both ends because the band takes
/// one: the shrinking end applies the same curve to the same distance and
/// subtracts it.
double _overshootOf(double raw, ResolvedDetents detents) {
  if (raw > detents.max.px) return raw - detents.max.px;
  if (raw < detents.min.px) return detents.min.px - raw;
  return 0;
}

/// What the panel shows for an accumulated un-resisted position of [raw].
///
/// The band is applied to the whole accumulated overshoot, not to this frame's
/// share of it, which is what makes the gesture path-independent: a hundred
/// one-pixel deltas and one hundred-pixel delta land in the same place.
Extent _appliedExtent(double raw, PanelModel owner) {
  final detents = owner.detents;
  final overshoot = _overshootOf(raw, detents);
  if (overshoot == 0) return Extent(raw);
  final applied = _bandOf(owner).map(overshoot);
  // Subtraction saturates at zero, so an overdrag deeper than the smallest
  // detent leaves a panel of no span rather than a negative one.
  return raw > detents.max.px ? detents.max + applied : detents.min - applied;
}

/// What a release at [overshoot] multiplies the finger's velocity by.
///
/// The derivative of the position the panel is *showing* with respect to the
/// position the finger is *at*: one inside the travel, where the panel tracks
/// the finger, and the band's slope beyond it, where it does not. So the settle
/// leaves at the speed the pixels were moving at, and a release from deep in an
/// overdrag does not project as though the panel had been keeping up with the
/// hand.
///
/// The two branches meet at a corner rather than smoothly — `slope(0)` is 0.55,
/// not 1 — and that corner is the band itself: the first pixel past a detent
/// moves at 55% of the finger. Reading `slope(0)` as the scale *inside* the
/// travel would resist a gesture that was never resisted.
double _releaseScale(double overshoot, PanelModel owner) =>
    overshoot == 0 ? 1.0 : _bandOf(owner).slope(overshoot);

/// The accumulated raw overshoot that shows an [applied] displacement — the
/// band run backwards, with its domain respected.
///
/// `RubberBand.map` asymptotes at one viewport, so a displacement at or past it
/// has no raw position to recover: the viewport shrank further than the band can
/// reach back over. That needs roughly 1600pt of accumulated overdrag before a
/// phone rotation, which is not a gesture — but the alternative to naming it is
/// an assert firing from inside a layout pass. The deepest overshoot the band
/// still answers is the closest a rebase can get, and a panel held that far past
/// its stop is taller than the viewport it is now in either way.
double _rawOvershootOf(Extent applied, PanelModel owner) {
  final band = _bandOf(owner);
  final asymptote = band.asymptote.px;
  return band.inverse(
    applied.clampTo(Extent.zero, Extent(asymptote * (1 - 1e-12))),
  );
}

/// The accumulated position a finger is measured from, and the three things
/// done to it.
///
/// [DragPanelActivity] and [ScrollDragActivity] are two classes because merging
/// them needs a nullable position, which is the defect this hierarchy is shaped
/// around. What they must not be is two *bodies*: a band applied one way on one
/// branch and another way on the other is a bug that reads as "the sheet feels
/// different when you drag the list", which nobody reports as a bug.
///
/// **Declared with no superclass constraint on purpose.** `on PanelActivity`
/// would read better and would make this a subtype of the sealed hierarchy,
/// which is exactly what must not happen: an exhaustive `switch` over
/// `PanelActivity` would then need a case for *this*, and that case would
/// silently absorb the next drag leaf to arrive — the compile error that makes
/// "a leaf without a policy does not build" true is worth more than the `on`
/// clause. So the two members it needs from its host are declared abstract here
/// and satisfied by the leaf.
mixin PanelDragMechanics {
  /// The model this gesture is driving — `PanelActivity.owner`.
  PanelModel get owner;

  /// The extent the gesture started at.
  Extent get from;

  /// The accumulated **un-resisted** position, in px on the extent axis.
  ///
  /// Freely outside the travel — that is the whole quantity. Keeping the
  /// un-resisted position rather than the applied one is what makes the rubber
  /// band path-independent: a hundred one-pixel deltas and one hundred-pixel
  /// delta land in the same place, where integrating resisted fragments does not
  /// (`smooth_sheets` integrates `kTouchSlop`-clamped pieces,
  /// `lib/src/physics.dart:213-236`, so the same gesture ends somewhere
  /// different at a different frame rate). It is also what lets a drag come back
  /// out of an overdrag 1:1 instead of resuming from a resisted position and
  /// compounding the resistance.
  double get rawExtent => _raw;
  late double _raw = from.px;

  /// How far past the nearest end of the travel the gesture has pulled, in px.
  ///
  /// Zero inside the travel. A magnitude at both ends, because the band takes a
  /// magnitude and the shrinking end subtracts it.
  double get rawOvershoot => _overshootOf(_raw, owner.detents);

  /// Moves the panel by [extentDelta] px, positive when the panel grows.
  ///
  /// The sign is already resolved: `PanelAnchor` is the only thing in the
  /// package that knows a bottom sheet grows when the finger rises, and it has
  /// been consulted before this is called. On the scroll-driven branch the share
  /// the panel is entitled to is already decided too — the split belongs to the
  /// scroll link, which is the only thing that can see both quantities.
  void update(double extentDelta) {
    _raw += extentDelta;
    owner.applyExtent(_appliedExtent(_raw, owner));
  }

  /// Puts [rawExtent] back under [shown] after the geometry moved beneath the
  /// finger.
  ///
  /// `LayoutCorrection.freeze` promises the panel does not move under a gesture,
  /// and writing nothing keeps that promise for exactly one pass: what the panel
  /// shows is recomputed from [rawExtent] against whatever travel and whatever
  /// band are current, so the next sample — a zero-pixel one will do — recomputes
  /// the whole gesture against the new geometry and teleports the panel by
  /// however far it moved. That is the yank the correction exists to prevent,
  /// one frame late.
  ///
  /// `RubberBand.inverse` is what recovers the accumulated position from a
  /// displacement, and `rawExtent`'s doc named it as the way to do exactly this
  /// while nothing called it.
  ///
  /// A no-op when the geometry under the gesture did not actually move: a real
  /// render pass commits a layout every frame and most of those frames change
  /// nothing, and a position round-tripped through the band on each of them
  /// would be a slow rounding drift in the one quantity the gesture *is*.
  void rebase(Extent shown) {
    if (_appliedExtent(_raw, owner) == shown) return;

    final detents = owner.detents;
    if (shown > detents.max) {
      _raw = detents.max.px + _rawOvershootOf(shown - detents.max, owner);
    } else if (shown < detents.min) {
      _raw = detents.min.px - _rawOvershootOf(detents.min - shown, owner);
    } else {
      _raw = shown.px;
    }
  }
}

/// A finger on the panel itself — the handle, the background, anything that is
/// not a scrollable.
///
/// The accumulated position and everything done to it are
/// [PanelDragMechanics], shared with the other branch's drag.
///
/// **Does not implement `Drag`.** The gesture interface lives in
/// `package:flutter/gestures.dart`, which the model layer does not import; the
/// widget layer adapts a `Drag` onto [update], [end] and [cancel]. DESIGN.md
/// §1.2 writes `implements Drag` here, and the layering rule the same document
/// states in §6 forbids it — the adapter is where the two are reconciled.
///
/// See [ScrollDragActivity], which does the same arithmetic on the other branch.
/// The two are not one class because that class would need a nullable position,
/// which is the defect this hierarchy is shaped to prevent.
final class DragPanelActivity extends SelfDrivenActivity
    with PanelDragMechanics {
  /// Starts a drag with the panel at [from].
  ///
  /// [from] seeds the un-resisted accumulated position, so the first delta is
  /// measured from where the finger actually landed rather than from wherever
  /// the panel happened to be after the previous gesture's overshoot.
  DragPanelActivity({required this.from});

  /// The extent the finger started at.
  @override
  final Extent from;

  /// Ends the drag at [velocity], which sends the panel ballistic.
  void end(ExtentVelocity velocity) => owner.goBallistic(
    ExtentVelocity(velocity.pxPerSecond * _releaseScale(rawOvershoot, owner)),
  );

  /// Ends the drag with no velocity, which settles the panel at the nearest
  /// detent.
  ///
  /// A release of zero projects to where the panel already is, so the detent
  /// nearest the projection *is* the detent nearest the panel — the same answer
  /// as [end], through the same code, with no separate "which detent is
  /// nearest" written down twice.
  void cancel() => end(ExtentVelocity.zero);

  /// [ExtentVelocity.zero]: a drag's speed is the recogniser's estimate and
  /// arrives at [end].
  @override
  ExtentVelocity get velocity => ExtentVelocity.zero;

  /// [LayoutCorrection.freeze].
  @override
  LayoutCorrection get onLayoutChanged => const LayoutCorrection.freeze();

  /// True.
  @override
  bool get isUserDriven => true;

  /// False — a finger supplies the frames.
  @override
  bool get isTicking => false;

  /// Ignores [delta].
  @override
  void tick(Duration delta) {}
}

/// A spring carrying the panel to a detent that has already been chosen.
///
/// Every self-driven motion the panel makes on its own is this one: a released
/// fling whose landing `snapTarget` has already projected, a programmatic
/// `animateTo`, and the re-target a [SettleWithin] correction commits. DESIGN.md
/// §1.2 lists a separate `BallisticPanelActivity` running an arbitrary
/// `Simulation`; on the self-driven branch there is no such simulation — the
/// destination is decided the instant the finger leaves — so the two would have
/// been one class with two names, and the design says to merge those.
final class SettlingPanelActivity extends SelfDrivenActivity {
  /// Springs from [from] to [to], entering at [velocity], under [motion].
  ///
  /// [to] is carried alongside [destination] rather than re-resolved, because a
  /// settle is seeded once from a baseline the caller had and ticked many times
  /// from wherever it is. Re-resolving per tick is the second copy of the
  /// arithmetic that decided it.
  ///
  /// [velocity] is seeded verbatim, **including when it points away from [to]**.
  /// A finger still travelling up when the panel has decided to settle down is a
  /// real gesture, and carrying it is what makes the curve read as attached to
  /// the hand.
  ///
  /// [tolerance] is how close to [to] this has to get before [isDone], in
  /// logical pixels. `PanelModel` passes half a physical pixel off the layout it
  /// last committed; a settle built by hand gets [kSettleTolerance], and the
  /// reason there is a default at all is that an activity is built before it is
  /// installed and so has nobody to ask.
  SettlingPanelActivity({
    required this.destination,
    required this.from,
    required this.to,
    required ExtentVelocity velocity,
    required this.motion,
    this.tolerance = kSettleTolerance,
  }) : assert(
         motion.duration >= kMinimumSettleDuration,
         'A spring of less than a millisecond is not a motion. '
         'SpringDescription.withDurationAndBounce measures its duration in '
         'whole milliseconds, so this one is a spring of no duration: in debug '
         'it refuses, and in release it is infinite stiffness, a NaN extent '
         'written every frame and an isDone that never comes true. A settle '
         'with no time left is an arrival — PanelModel parks instead of '
         'building this, and LayoutCorrection.settle resolves to the '
         'destination instead of asking for it.',
       ),
       _simulation = motion.createSimulation(
         start: from.px,
         end: to.px,
         velocity: velocity.pxPerSecond,
         // Distance and velocity, both in the panel's own units: the settle is
         // over when it is inside half a pixel of its destination and moving
         // slower than half a pixel a second. Leaving the velocity at the
         // default 1e-3 px/s would hold a finished panel ticking for a further
         // third of a second to cross a distance no display has a pixel for.
         tolerance: Tolerance(distance: tolerance, velocity: tolerance),
       );

  /// The detent being settled at.
  final Detent destination;

  /// Where the spring started.
  final Extent from;

  /// Where it is going, as resolved when the settle was decided.
  final Extent to;

  /// The spring's shape and nominal duration.
  final PanelMotion motion;

  /// How close to [to] this settle has to get before it stops, in logical
  /// pixels.
  final double tolerance;

  /// The spring being integrated, seeded once when the settle was decided.
  final Simulation _simulation;

  /// How long this activity has been running.
  Duration get elapsed => _elapsed;
  Duration _elapsed = Duration.zero;

  /// [elapsed] in seconds, which is what a `Simulation` is sampled in.
  double get _seconds =>
      _elapsed.inMicroseconds / Duration.microsecondsPerSecond;

  /// `motion.duration - elapsed`, floored at [Duration.zero].
  ///
  /// This is what a [SettleWithin] correction carries, and flooring it is what
  /// makes repeated corrections converge: no re-seed is longer than the one
  /// before, and every one with a frame between them is strictly shorter, so
  /// content that keeps changing shortens the settle instead of restarting it.
  Duration get remaining =>
      _elapsed >= motion.duration ? Duration.zero : motion.duration - _elapsed;

  /// Whether the simulation has reached its tolerance.
  ///
  /// The tolerance is a distance, half a physical pixel — the same threshold
  /// `Extent.isCloseTo` uses. The default `Tolerance` is calibrated for a 0..1
  /// route animation and over a span in logical pixels settles about a thousand
  /// times tighter than the screen can show, which is a tail of frames nobody
  /// can see.
  ///
  /// Deliberately **not** `remaining == Duration.zero`. A spring's nominal
  /// duration is perceptual and it is still moving when that duration is up: a
  /// critically damped 500ms spring over the 342pt between medium and full is
  /// 4.7pt short at t = 500ms, and reaches half a physical pixel about 350ms
  /// later. A settle driven only by [tick] runs that out. A settle that meets a
  /// layout pass in that window is finished by it instead, because
  /// [SettleWithin.hasArrived] is what a correction reads and there is no spring
  /// left to hand it — and both ways the panel's last extent is [to].
  bool get isDone => _simulation.isDone(_seconds);

  /// The simulation's derivative at [elapsed] — what the spring is doing now.
  @override
  ExtentVelocity get velocity => ExtentVelocity(_simulation.dx(_seconds));

  /// [LayoutCorrection.settle] of [destination] and [remaining].
  @override
  LayoutCorrection get onLayoutChanged =>
      LayoutCorrection.settle(destination, remaining);

  /// False.
  @override
  bool get isUserDriven => false;

  /// True until [isDone].
  @override
  bool get isTicking => !isDone;

  /// Advances the spring, writes the extent, and parks at [destination] once
  /// [isDone].
  ///
  /// The arrival goes through `PanelModel.arriveAt` rather than through
  /// `applyExtent` followed by `goIdle`, because those are two notifications for
  /// one event: the final frame of a settle would fire twice where every other
  /// frame fires once, and a listener that rebuilds on each does the work of a
  /// frame twice in the frame a route, a barrier and a scroll link are all
  /// already reacting to.
  ///
  /// The last write is [to] itself rather than the simulation's own last sample,
  /// which is inside a tolerance of it: a panel that parks at its destination
  /// should be *at* its destination, so that the height a later `hold` resolves
  /// to is the height it is already showing and there is no sub-pixel step
  /// between arriving and being told where it arrived.
  ///
  /// **The sample is saturated at zero, and this is the only write in the
  /// package that needs saying so.** A spring with any bounce at all undershoots
  /// a destination near the bottom of the travel — measured, a floating panel
  /// settling to a zero-height detent under [PanelMotion.snappy] dips to −1.26pt
  /// at *zero* release velocity, and under `bouncy` to −4.9 — and an [Extent] is
  /// "finite and non-negative by convention" everywhere else: `Extent.operator -`
  /// saturates, `PanelBaseline.frameOf` saturates, `Detent.resolve` asserts. This
  /// write is the one crossing that reaches [PanelModel.applyExtent] without
  /// passing through any of them, and a negative extent leaves the model as an
  /// inverted rect and arrives at `BoxConstraints.tight` — where the *framework*
  /// refuses, three layers below the spring that did it.
  ///
  /// Zero is the floor rather than some smaller number because below zero the
  /// panel is not short, it is *absent*, and absence is [EdgeOffset]'s quantity
  /// and not this one. The pixels the spring spends under the floor are not lost:
  /// the simulation keeps integrating from its own unclamped position, so the
  /// bounce comes back up on its own schedule and the panel simply rests at zero
  /// while it is beneath it.
  @override
  void tick(Duration delta) {
    _elapsed += delta;
    final owner = _owner;
    if (owner == null) return;
    if (isDone) {
      owner.arriveAt(to, target: destination);
      return;
    }
    owner.applyExtent(Extent(math.max(0.0, _simulation.x(_seconds))));
  }
}

/// A panel being moved by a scrollable inside it.
///
/// [position] is **non-nullable**, and that is the entire reason this branch
/// exists. Everything on it can ask where the list is scrolled to without
/// asking first whether there is a list.
sealed class ScrollDrivenActivity extends PanelActivity {
  /// The scroll position driving the panel.
  ///
  /// Typed as [PanelScrollDriver] rather than as the eventual
  /// `PanelScrollPosition`, because `ScrollPosition` lives behind
  /// `package:flutter/widgets.dart` and the model layer imports no binding. The
  /// scroll layer's position implements this interface; nothing else does.
  PanelScrollDriver get position;
}

/// The narrow view of a scroll position that the model needs.
///
/// Three scalars, which is everything the split policy and the fused axis ask
/// of a scrollable: where it is, and where its ends are. It exists so that
/// [ScrollDrivenActivity.position] can be non-nullable and concrete in a layer
/// that cannot name `ScrollPosition`.
///
/// Implemented by `PanelScrollPosition` in `lib/src/scroll/position.dart` when
/// that lands. Written as an interface rather than as a typedef so a test can
/// supply a fake without a binding.
abstract interface class PanelScrollDriver {
  /// Where the scrollable currently is, in its own pixel space.
  double get pixels;

  /// The offset of the scrollable's start — the SDK header's "scrolled to top".
  double get minScrollExtent;

  /// The offset of the scrollable's end.
  double get maxScrollExtent;
}

/// A finger on a scrollable inside the panel, with the panel taking its share
/// of the delta first.
///
/// Does the same arithmetic as [DragPanelActivity] and answers the same
/// [LayoutCorrection.freeze] for the same reason, and is a separate class
/// anyway: merging them would need a nullable [position], which is the
/// `smooth_sheets` defect this hierarchy is shaped around. The design's rule is
/// to merge two leaves with identical corrections *and* identical tick
/// behaviour; the qualifier it needs is "within the same branch", because the
/// branch itself is what these two do not share.
final class ScrollDragActivity extends ScrollDrivenActivity
    with PanelDragMechanics {
  /// Starts a scroll-driven drag with the panel at [from], driven by [position].
  ScrollDragActivity({required this.position, required this.from});

  @override
  final PanelScrollDriver position;

  /// The extent the gesture started at.
  @override
  final Extent from;

  /// Ends the gesture at [velocity], which sends the panel and the list into one
  /// fused ballistic.
  ///
  /// The ballistic keeps [position], which is what makes it one fling across two
  /// things rather than a panel settle that happens to be followed by a scroll:
  /// the fused axis is only constructible from both ends of it.
  ///
  /// A release the fling would not want a single frame for is handed to [cancel]
  /// instead. A fling that never gets a frame never gets to end either — nothing
  /// ticks an activity that reports `isTicking` false — so it would stay
  /// installed for the life of the panel, freezing every later layout change.
  /// The finger that stops before it lifts produces exactly that release, and
  /// under a zero re-snap window there is then nothing at all left to spend.
  void end(ExtentVelocity velocity) {
    final fling = ScrollBallisticActivity(
      position: position,
      velocity: ExtentVelocity(
        velocity.pxPerSecond * _releaseScale(rawOvershoot, owner),
      ),
      resnapWindow: owner.config.resnapWindow,
    );
    if (!fling.isTicking) return cancel();
    owner.beginActivity(fling);
  }

  /// Ends the gesture with no velocity.
  ///
  /// Hands the panel back to its own settle rather than to a fused ballistic of
  /// zero: there is no throw to carry across the seam, so there is nothing to
  /// fuse, and the list keeps the offset it was cancelled at.
  void cancel() => owner.goBallistic(ExtentVelocity.zero);

  /// [ExtentVelocity.zero], for [DragPanelActivity.velocity]'s reason.
  @override
  ExtentVelocity get velocity => ExtentVelocity.zero;

  /// [LayoutCorrection.freeze].
  @override
  LayoutCorrection get onLayoutChanged => const LayoutCorrection.freeze();

  /// True.
  @override
  bool get isUserDriven => true;

  /// False.
  @override
  bool get isTicking => false;

  /// Ignores [delta].
  @override
  void tick(Duration delta) {}

  /// Releases [position].
  ///
  /// Nothing to release yet: [PanelScrollDriver] is three getters, so a model
  /// layer that cannot name `ScrollPosition` also cannot unbind one. The
  /// unbinding this doc originally promised belongs to `PanelScrollPosition`,
  /// which owns both ends of the link and is where `absorb` will hand it across;
  /// this override is the seam it lands on, and [PanelActivity.isDisposed] is
  /// how a test can see it has been reached.
  @override
  void dispose() => super.dispose();
}

/// One fling crossing the panel and the list inside it.
///
/// The only leaf that produces [LayoutCorrection.resnap], and the reason the
/// variant exists: the fused axis spans the panel's travel plus the list's
/// scrollable distance, so content that grows mid-flight rescales the axis and
/// moves the seam. A projection made against the old axis lands somewhere that
/// is no longer there.
///
/// Re-snapping stops after [resnapWindow]. Past it this answers
/// [LayoutCorrection.freeze], because a fling that kept re-choosing its
/// destination for its whole flight would chase every content change and commit
/// to nothing.
final class ScrollBallisticActivity extends ScrollDrivenActivity {
  /// Flings from the panel's current extent at [velocity], driven by [position].
  ///
  /// [resnapWindow] comes from `PanelConfig.resnapWindow` rather than from a
  /// literal here, because 150ms is a feel and not a measurement, and a number
  /// nobody has tried the other side of is a hardcoded choice with extra steps.
  ScrollBallisticActivity({
    required this.position,
    required ExtentVelocity velocity,
    required this.resnapWindow,
  }) : _simulation = FrictionSimulation(
         kDecelerationDrag,
         0,
         velocity.pxPerSecond,
       );

  @override
  final PanelScrollDriver position;

  /// How long this activity keeps re-choosing its landing after a layout
  /// change.
  final Duration resnapWindow;

  /// The deceleration this fling is spending, from the release onward.
  ///
  /// Seeded at position zero because only its derivative is read here: where the
  /// fling *is* on the fused axis is `FusedAxis`'s answer, and that type is not
  /// built. The constant is [kDecelerationDrag], so the velocity this reports and
  /// the landing `projectLanding` computes come from one deceleration rather
  /// than from two literals that could drift apart.
  final Simulation _simulation;

  /// How long this activity has been running.
  Duration get elapsed => _elapsed;
  Duration _elapsed = Duration.zero;

  /// [elapsed] in seconds, which is what a `Simulation` is sampled in.
  double get _seconds =>
      _elapsed.inMicroseconds / Duration.microsecondsPerSecond;

  /// Whether [elapsed] is still inside [resnapWindow].
  ///
  /// A zero window means this is false from the first frame, which is the
  /// "never re-snap" end of the policy and is a supported configuration rather
  /// than a degenerate one.
  bool get isResnapping => _elapsed < resnapWindow;

  /// The fling's derivative at [elapsed], on the extent axis.
  ///
  /// DESIGN.md §3.3 makes this the *fused* simulation's derivative, zero once
  /// the fling has crossed the seam into the list's share of the axis. The seam
  /// is `FusedAxis`, which `lib/src/physics/fused_axis.dart` does not yet
  /// contain, so what this reports is the same deceleration over the panel's
  /// share alone: correct until the seam, and the place the fused sample lands
  /// when the axis exists.
  @override
  ExtentVelocity get velocity => ExtentVelocity(_simulation.dx(_seconds));

  /// [LayoutCorrection.resnap] of [velocity] while [isResnapping], and
  /// [LayoutCorrection.freeze] after.
  @override
  LayoutCorrection get onLayoutChanged => isResnapping
      ? LayoutCorrection.resnap(velocity)
      : const LayoutCorrection.freeze();

  /// False.
  @override
  bool get isUserDriven => false;

  /// True while either the throw or the window it re-snaps in is still running.
  ///
  /// The window half is what makes the "and then stops re-snapping" half of the
  /// policy reachable at all. [isResnapping] is measured on this activity's own
  /// clock, that clock only advances in [tick], and a driver stops calling
  /// [tick] the moment this goes false — so a fling whose `FrictionSimulation`
  /// is already done at t = 0 would never start the clock that closes its own
  /// window. Any release under 1e-3 px/s is such a fling, which is a finger that
  /// stopped before it lifted, and the panel would answer `resnap` to every
  /// layout change for the rest of its life.
  @override
  bool get isTicking => isResnapping || !_simulation.isDone(_seconds);

  /// Advances this activity's clock and, once there is nothing left to spend,
  /// hands the panel back to its own settle.
  ///
  /// **The half that moves things is not here yet, and it is not being faked.**
  /// DESIGN.md has this write both ends of one fused simulation — the panel's
  /// extent and the list's pixels — and neither is reachable from the model
  /// layer as it stands: `FusedAxis` and `FusedSimulation` are unbuilt, and
  /// [PanelScrollDriver] is three getters, so the list's offset cannot be
  /// written through it at all. Running a panel-only simulation here instead
  /// would be the second simulation the design's own falsification criterion 4
  /// forbids, and the fused one would then have to delete it.
  ///
  /// The handoff is not deferred with it, because without one this activity is
  /// terminal: the throw runs out, [isTicking] goes false, and an activity that
  /// is never replaced answers `freeze` to every layout change after it — a
  /// panel that can no longer follow a rotation or a keyboard, sitting at a
  /// height that need not be any of its detents. `applyLayout`'s
  /// `ResnapBallistic` arm refuses to hand a live fling to a self-driven settle
  /// because that drops the position which makes it one gesture across two
  /// things; here the throw is spent and the window is closed, so there is
  /// nothing left to be one gesture *with*.
  @override
  void tick(Duration delta) {
    _elapsed += delta;
    if (!isTicking) _owner?.goBallistic(velocity);
  }

  /// Releases [position]. See [ScrollDragActivity.dispose] — nothing to release.
  @override
  void dispose() => super.dispose();
}
