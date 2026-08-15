import 'package:flutter/foundation.dart';

import '../geometry/detent.dart';
import '../geometry/detent_set.dart';
import '../geometry/layout.dart';
import '../geometry/units.dart';
import '../physics/motion.dart';
import '../physics/snap.dart';
import 'activity.dart';
import 'correction.dart';

/// How long a fling keeps re-choosing its landing after the layout changes
/// under it.
///
/// **Unmeasured.** It is the window in which a content change is still plausibly
/// part of the same event as the fling — a page settling a frame or two after it
/// started — rather than a separate thing happening later. Too long and a panel
/// chases every content change instead of arriving; too short and a fling
/// launched at the moment a list finished loading lands at a stale detent.
///
/// It is a default on [PanelConfig.resnapWindow] and not a constant in the
/// ballistic activity, because it is a feel and every feel in this package is a
/// named policy with both ends tested.
const Duration kResnapWindow = Duration(milliseconds: 150);

/// Everything about a panel that the model needs and the layout does not
/// supply.
///
/// A value type, and the equality is load-bearing: [PanelModel.updateConfig] is
/// called on every rebuild of the widget above it, and a config that compared
/// unequal each time would re-resolve the detents and snap the panel on every
/// frame. That is G10 read from the wrong end.
@immutable
final class PanelConfig {
  /// Configures a panel with [detents] and defaults for everything else.
  const PanelConfig({
    required this.detents,
    this.initialDetent,
    this.snapPolicy = SnapPolicy.projected,
    this.motion = const PanelMotion.smooth(),
    this.resnapWindow = kResnapWindow,
    this.bandResistance = 0.55,
  });

  /// The heights the panel may rest at, in authoring order.
  final DetentSet detents;

  /// Which of [detents] to open at, or null for the smallest active one.
  final Detent? initialDetent;

  /// How far a single fling is allowed to travel through [detents].
  final SnapPolicy snapPolicy;

  /// The spring every settle uses unless a correction shortens it.
  final PanelMotion motion;

  /// How long a fling keeps re-choosing its landing after a layout change.
  ///
  /// [Duration.zero] disables re-snapping entirely, which is the other end of
  /// the policy and is tested as such.
  final Duration resnapWindow;

  /// The rubber band's marginal resistance at zero overshoot — `RubberBand.c`.
  ///
  /// Carried here rather than left at the band's own default because a panel
  /// author has no other way to reach it: the band is constructed per layout
  /// pass from a viewport the model measures, so there is no call site for them
  /// to pass one at.
  final double bandResistance;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PanelConfig &&
          other.detents == detents &&
          other.initialDetent == initialDetent &&
          other.snapPolicy == snapPolicy &&
          other.motion == motion &&
          other.resnapWindow == resnapWindow &&
          other.bandResistance == bandResistance;

  @override
  int get hashCode => Object.hash(
    detents,
    initialDetent,
    snapPolicy,
    motion,
    resnapWindow,
    bandResistance,
  );

  @override
  String toString() =>
      'PanelConfig($detents, initialDetent: $initialDetent, '
      'snapPolicy: ${snapPolicy.name}, motion: $motion, '
      'resnapWindow: $resnapWindow, bandResistance: $bandResistance)';
}

/// The two scalars a panel is, the activity moving them, and the one place a
/// layout change is applied.
///
/// **Owns no ticker.** DESIGN.md §2.4 gives this constructor a `TickerProvider`;
/// the layering rule in §6 of the same document says the model layer adds only
/// `foundation` to what geometry and physics may import, and `TickerProvider`
/// lives in `package:flutter/scheduler.dart`, which carries a binding. The
/// layering wins, and the model keeps its simulations while the widget above it
/// keeps the `Ticker` and calls [tick]. What that buys is the reason the rule
/// exists: every test under `test/model/` is a plain `test`, with no binding, no
/// pump and no fake async.
///
/// The state is deliberately two scalars that are never multiplied — [extent] is
/// how big the panel is and [edgeOffset] is how far it has come — and this slice
/// pins the second at [EdgeOffset.zero]. Dismissal is what moves it, and
/// dismissal is not in this slice.
final class PanelModel extends ChangeNotifier {
  /// Opens a panel at `config.initialDetent`, resolved against [layout].
  ///
  /// The initial activity is [IdlePanelActivity] at that detent — not at that
  /// height. A panel that recorded its opening height would not follow a
  /// rotation that happened before anything else touched it.
  PanelModel({required PanelConfig config, required PanelLayout layout})
    : _config = config,
      _layout = layout,
      _detents = config.detents.resolve(layout.baseline) {
    _extent = _detents.select(config.initialDetent);
    // The detent, not the height — and the detent the *author* named, which is
    // not always the one `select` opened at. `select` falls back to the smallest
    // active stop when the named detent resolved to nothing, and recording that
    // fallback as the target would make it permanent: a panel opened at
    // `.medium` on a phone already on its side, where iOS deactivates medium,
    // would be parked at `.full` forever and turning the phone upright would
    // leave it there. Keeping the named detent is `LayoutCorrection.hold`'s rule
    // applied at frame zero — sit at the nearest surviving height now, and be
    // 469.68 the moment that height exists again.
    _activity = IdlePanelActivity(
      target: config.initialDetent ?? _detents.snaps.first.$1,
    )..attach(this);
  }

  /// The current configuration.
  PanelConfig get config => _config;
  PanelConfig _config;

  /// The layout of the last committed pass.
  PanelLayout get layout => _layout;
  PanelLayout _layout;

  /// [config]'s detents resolved against [layout]'s baseline.
  ///
  /// Re-resolved when the layout or the config changes, not on every read: a
  /// resolution allocates a list and sorts it, and this is read by the barrier,
  /// the handle and the scroll link on every frame.
  ResolvedDetents get detents => _detents;
  ResolvedDetents _detents;

  /// How big the panel is: the frame span from the attachment edge to the
  /// leading edge.
  Extent get extent => _extent;
  late Extent _extent;

  /// How far the panel's attachment edge sits from the viewport's.
  ///
  /// [EdgeOffset.zero] throughout this slice. It moves when dismissal lands, and
  /// nothing else ever moves it — a detent changes [extent] and leaves this
  /// where the placement rests it, which is what makes a barrier fully opaque at
  /// every detent.
  EdgeOffset get edgeOffset => EdgeOffset.zero;

  /// Where this panel's placement rests when it is fully present.
  ///
  /// [EdgeOffset.zero] for every placement this slice ships, because they are
  /// all edge-attached. A centred dialog rests at `(viewportSpan - extent) / 2`,
  /// and measuring presentation from zero instead would report a 300pt dialog in
  /// an 874pt viewport as 4% present while it is on screen and opaque. The seam
  /// is named here so that `Placement` has somewhere to arrive.
  EdgeOffset get restingOffset => EdgeOffset.zero;

  /// How present the panel is, in `[0, 1]` — the route animation's value.
  ///
  /// Derived from [edgeOffset] and [restingOffset], never driven, and so 1.0 at
  /// every detent and throughout this slice.
  double get presentationProgress =>
      edgeOffset.presentationProgress(_extent, restingOffset: restingOffset);

  /// What the panel is currently doing.
  PanelActivity get activity => _activity;
  late PanelActivity _activity;

  /// Whether [activity] needs frames — `activity.isTicking`, forwarded so the
  /// widget driving the ticker does not reach through the activity to ask.
  bool get isTicking => _activity.isTicking;

  /// The extent this panel would take if [next] were committed.
  ///
  /// **Pure: commits nothing and notifies nobody.** Called by the render object
  /// before it lays the child out, because the child's constraints depend on the
  /// answer and the answer must not depend on the child.
  ///
  /// It is the same expression [applyLayout] commits — one call to
  /// `activity.onLayoutChanged.resolve` — so the two cannot disagree. That is
  /// the whole shape: `smooth_sheets` ships two implementations and a runtime
  /// assert that they agreed (`lib/src/model.dart:345-361`), comparing values
  /// fresh out of a spring with `==` on `double`.
  Extent dryApplyLayout(PanelLayout next) => _resolve(
    _activity.onLayoutChanged,
    next,
    _config.detents.resolve(next.baseline),
  );

  /// The one expression both passes go through, tripwire included.
  ///
  /// [detents] is passed in rather than resolved here because the commit needs
  /// the same list afterwards — to write it, and to re-resolve a settle's
  /// destination against it — and resolving twice in one pass would allocate and
  /// sort twice for an answer that cannot have changed in between. [correction]
  /// likewise: the commit switches on the same one it resolved through.
  ///
  /// The purity assert lives here rather than in [applyLayout] so that it covers
  /// the call that runs *first*. [dryApplyLayout] is read before the child is
  /// laid out, which is the reading where a correction that notified would
  /// rebuild a widget that is mid-layout; [applyLayout] runs at the end of the
  /// pass. Guarding only the second one guarded the safer of the two.
  Extent _resolve(
    LayoutCorrection correction,
    PanelLayout next,
    ResolvedDetents detents,
  ) {
    final extent = correction.resolve(next, _extent, detents);
    assert(_purely(next, detents, correction, extent));
    return extent;
  }

  /// Commits [next] and the extent it implies, then hands the activity on.
  ///
  /// **[dryApplyLayout] plus the commit, with nothing in between.** There is no
  /// early-out on `next == layout`, and there must not be: a correction is a
  /// function of the *activity* as much as of the layout, so a pass that changes
  /// no geometry still has an answer, and skipping it is a second commit path
  /// that answers "whatever the extent already was". [goIdle] is the plainest
  /// case — it parks at a detent without moving the panel and leaves the next
  /// pass to say where that detent is, and a pass that refused to resolve never
  /// says. The panel then paints at one number and every consumer of [extent]
  /// reads another, stably, until a gesture starts.
  ///
  /// What the early-out was actually carrying was a notification, and that is
  /// answered by comparing the **outcome**: a pass that leaves the layout, the
  /// detents, the extent and the activity where it found them tells nobody
  /// anything. A pass that moves any of them notifies exactly once, for the
  /// whole commit — so a panel settling under an unchanged layout notifies from
  /// [tick] rather than twice a frame.
  ///
  /// The other thing [dryApplyLayout] does not do is the correction's *other*
  /// half: an exhaustive `switch` that re-seeds a settle toward its re-resolved
  /// destination, rebases the gesture a freeze is holding, or leaves the
  /// activity alone. That is why the correction is a sealed value and not a bare
  /// [Extent].
  void applyLayout(PanelLayout next) {
    final correction = _activity.onLayoutChanged;
    final detents = _config.detents.resolve(next.baseline);
    final extent = _resolve(correction, next, detents);

    // Read before the writes, because after them there is nothing to compare to.
    final moved = extent != _extent || detents != _detents || next != _layout;
    final previousDetents = _detents;
    final previousActivity = _activity;

    _layout = next;
    _detents = detents;
    _extent = extent;

    // The correction's other half. `resolve` above answered where the panel is;
    // this answers what it is still doing, and it is deliberately not inside
    // `resolve` — re-seeding a spring allocates an activity and reads a clock,
    // and the sizing pass calls `resolve` before the child is laid out.
    //
    // Nothing in here may move [extent]. The dry pass has already been believed
    // by the render object, which laid the child out against it, so a commit
    // that disagreed would be the divergence this whole shape exists to prevent,
    // arrived at from the other side. Which is why everything that answers with
    // a height is on the other side of the seam and nothing here is.
    switch (correction) {
      // The finger owns the panel and the layout does not get a say about where
      // it is — but the accumulated position the finger is measured *from* has
      // to follow the geometry, or the freeze lasts exactly one pass.
      case FreezeExtent():
        _rebaseGesture();
      // `resolve` re-resolved the detent, which is the whole of it.
      case HoldDetent():
        break;
      case final SettleWithin settle:
        _continueSettle(settle, previousDetents);
      // Nothing to re-project onto yet: a fling's landing lives on the fused
      // axis, `FusedAxis` is unbuilt, and re-running `snapTarget` here would
      // hand a scroll-driven fling to a self-driven settle and drop the position
      // that makes it one gesture across two things.
      case ResnapBallistic():
        break;
    }

    if (moved || !identical(_activity, previousActivity)) notifyListeners();
  }

  /// The commit half of a [SettleWithin]: finish the settle, re-seed it, or
  /// leave it running.
  ///
  /// **Finish it** once [SettleWithin.hasArrived]. `resolve` has already put the
  /// panel on its destination — that is what arriving means on the side of the
  /// seam that may answer with a height — so all that is left here is to say the
  /// settle is over. The alternative is the state this whole band is guarded
  /// against: a spring of no duration, which is infinite stiffness and a `NaN`
  /// extent in release and a refusal from inside a layout pass in debug.
  ///
  /// **Re-seed it** when the destination actually moved — from where the spring
  /// is, at the speed it is going, in the time that was left. [previous] is what
  /// decides, and it is the outcome and not the layout that is compared:
  /// `applyLayout` runs once per frame in a real render pass and most of those
  /// frames move nothing, while a keyboard moves `viewInsets` and no detent. A
  /// settle re-seeded on a pass that moved nothing is a different spring every
  /// frame whose own clock restarts each time, and it never converges.
  ///
  /// Each re-seed carries [SettleWithin.remaining] rather than a fresh duration,
  /// so a destination that keeps moving shortens the settle instead of
  /// restarting it. Two re-seeds with no frame between them are equal in length,
  /// not shorter — the clock is what shortens them — and that is the whole of
  /// the convergence argument.
  void _continueSettle(SettleWithin settle, ResolvedDetents previous) {
    if (settle.hasArrived) {
      _begin(IdlePanelActivity(target: settle.destination), notify: false);
      return;
    }
    if (heightOf(settle.destination, _extent, _detents) ==
        heightOf(settle.destination, _extent, previous)) {
      return;
    }
    _settle(
      settle.destination,
      within: settle.remaining,
      // The running settle's own spring, not the config's: shortening a settle
      // must not also reshape it, and `animateTo(motion: bouncy)` installs one
      // whose shape the config does not have.
      motion: _runningShape,
      notify: false,
    );
  }

  /// Puts a gesture's accumulated position back under the pixels a freeze kept.
  ///
  /// See [PanelDragMechanics.rebase] for what goes wrong without it. Keyed on
  /// the correction rather than on the activity because the correction is the
  /// promise — `freeze` says the panel does not move under the finger, and this
  /// is what makes that true for longer than one pass. Nothing else answers
  /// `freeze` with a position to rebase, so nothing else is touched.
  void _rebaseGesture() {
    // An if-case and not an `is` test: [PanelDragMechanics] is deliberately
    // outside the sealed hierarchy — see its own doc — so there is no subtype
    // relation for flow analysis to promote along, and the pattern is what binds
    // the gesture at the type that has the seam.
    if (_activity case final PanelDragMechanics gesture) {
      gesture.rebase(_extent);
    }
  }

  /// The debug tripwire: [_resolve] is a function of its arguments.
  ///
  /// Not a divergence check — there is one implementation, so there is nothing
  /// for it to diverge from. It watches the property that replaced the check:
  /// that asking twice asks the same question, and that asking tells nobody
  /// anything. `smooth_sheets` compares two implementations' results with `==`
  /// on a `double` fresh out of a spring (`lib/src/model.dart:345-361`); this
  /// compares one implementation with itself, where exact equality is the
  /// correct comparison and not an optimistic one.
  bool _purely(
    PanelLayout next,
    ResolvedDetents detents,
    LayoutCorrection correction,
    Extent extent,
  ) {
    // The second reading is the guarded one. A correction that notifies notifies
    // from both readings, so guarding one catches it — and guarding only one
    // keeps the flag out of the path the commit actually takes. It is also the
    // reading that must not recurse into _resolve, which asserts this.
    _resolving = true;
    final asked = _activity.onLayoutChanged;
    final again = asked.resolve(next, _extent, detents);
    _resolving = false;

    assert(
      asked == correction,
      'One activity was asked what a layout change means to it twice in one '
      'pass, with nothing happening in between, and answered differently. The '
      'sizing pass and the commit are then answering different questions, '
      'however pure resolve() is.',
    );
    assert(
      again == extent,
      'One correction resolved the same layout, extent and detents to two '
      'different spans. resolve() has stopped being a function of its '
      'arguments, which is the one thing that makes the two passes agree.',
    );
    return true;
  }

  /// True while a correction is being read, which is when notifying is
  /// forbidden.
  ///
  /// Only ever written by [_purely], which only ever runs inside an `assert`, so
  /// this is false in a release build and [notifyListeners]' guard compiles out
  /// with it.
  bool _resolving = false;

  /// Notifies, unless a layout correction is being resolved.
  ///
  /// The other half of the purity tripwire, and it sits here rather than on a
  /// temporary listener because this is the one path a violation can take: a
  /// correction that notifies has called *this*. The failure it names is real —
  /// `resolve` runs inside a layout pass, and a listener that rebuilds from
  /// there rebuilds a widget that is mid-layout.
  @override
  void notifyListeners() {
    assert(
      !_resolving,
      'A layout correction notified while it was being resolved. resolve() is '
      'read inside a layout pass, twice, and it must answer out of its '
      'arguments alone — it may not tell anybody anything.',
    );
    super.notifyListeners();
  }

  /// Adopts [next], re-resolving the detents and re-snapping if the set changed.
  ///
  /// G10 lives here. A no-op when `next == config`, which is the common case:
  /// the widget above rebuilds and hands over a config equal to the one it
  /// handed over last frame. When the set genuinely changed the panel settles to
  /// the nearest surviving detent under [PanelConfig.motion] — it does not jump,
  /// because a page change that swaps four detents for two is the same event as
  /// the panel resizing between them.
  ///
  /// A config change under a user-driven activity does not interrupt the
  /// gesture: the finger keeps the panel, and the new set applies when it lets
  /// go.
  void updateConfig(PanelConfig next) {
    if (next == _config) return;

    final previous = _detents;
    _config = next;
    _detents = next.detents.resolve(_layout.baseline);

    // G10. The set changing is what snaps, not the config changing: a page that
    // swaps a spring or a scroll policy has not moved the panel, and re-snapping
    // on it would be the every-frame re-target the value equality above exists
    // to prevent, one level down.
    //
    // And only a self-driven activity is re-targeted. A finger keeps the panel,
    // which is what `isUserDriven` says; a scroll-driven *fling* keeps its
    // landing for the reason `applyLayout`'s `ResnapBallistic` arm gives —
    // running `snapTarget` over it hands one gesture across two things to a
    // settle that has only one of them, and drops the position that made it one.
    // Read through `isUserDriven` alone this branch did exactly what that arm
    // refuses to do, on a change the fling can neither see nor survive.
    if (_detents != previous &&
        _activity is SelfDrivenActivity &&
        !_activity.isUserDriven) {
      _settle(_detents.nearestTo(_extent), notify: false);
    }
    // Whatever the set did, the pixels under a finger stay where they are. The
    // travel and the band are both read live off this model, so a config that
    // changes either — a new detent set, a different `bandResistance` — moves
    // the panel on the very next delta unless the accumulated position is put
    // back under it. "The finger keeps the panel" is not kept by declining to
    // re-target.
    _rebaseGesture();

    notifyListeners();
  }

  /// Installs [activity], disposing the outgoing one.
  ///
  /// The single seam every state change goes through, so there is exactly one
  /// place an activity is attached and exactly one place its predecessor is
  /// disposed. Notifies, because `isUserDriven` and [isTicking] both changed for
  /// anything that was watching them.
  void beginActivity(PanelActivity activity) => _begin(activity);

  /// [beginActivity], with the notification made optional.
  ///
  /// The commit half of a [LayoutCorrection] and a config adoption both install
  /// an activity partway through a change that notifies once at its end. Without
  /// this they would notify twice for one event, and a listener that rebuilt on
  /// each would do the work of a frame in the middle of a frame.
  void _begin(PanelActivity next, {bool notify = true}) {
    _activity.dispose();
    _activity = next..attach(this);
    if (notify) notifyListeners();
  }

  /// Parks the panel at [target].
  ///
  /// Installs the activity and does not touch [extent]: an idle panel is *at* a
  /// detent, and where that detent is is a question for the next layout pass,
  /// which answers it with [LayoutCorrection.hold]. Moving the panel here would
  /// make parking a jump, and would put a second writer of the extent inside the
  /// commit path, where the sizing pass has already been believed.
  void goIdle({required Detent target}) =>
      _begin(IdlePanelActivity(target: target));

  /// Releases the panel at [velocity], settling it wherever the fling projects.
  ///
  /// Runs `snapTarget` under [PanelConfig.snapPolicy] and installs a
  /// [SettlingPanelActivity] seeded with [velocity] verbatim — including when it
  /// points away from the detent that was chosen, which is the case a release
  /// mid-travel produces and the case `smooth_sheets` substitutes zero for
  /// (`lib/src/physics.dart:114-118`).
  void goBallistic(ExtentVelocity velocity) {
    final decision = snapTarget(
      from: _extent,
      velocity: velocity,
      detents: _detents,
      policy: _config.snapPolicy,
    );
    // The decision carries the height it chose, so nothing re-resolves it here —
    // a second copy of the arithmetic that decided it is how a fling lands in
    // one place and snaps to another.
    _settleAt(
      decision.detent,
      decision.extent,
      velocity: decision.velocity,
      motion: _config.motion,
    );
  }

  /// Settles at [detent], continuing whatever the panel is already doing.
  ///
  /// Seeded with `activity.velocity`, so a settle installed over a running one
  /// picks the motion up rather than restarting it. [within] overrides the
  /// duration and is how a [SettleWithin] correction preserves the time that was
  /// left; the spring's bounce comes from [PanelConfig.motion] either way, so a
  /// shortened settle is the same spring in less time and not a different one.
  void settleTo(Detent detent, {Duration? within}) =>
      _settle(detent, within: within);

  /// Animates to [detent] from rest.
  ///
  /// The programmatic entry point, and the difference from [settleTo] is the
  /// seed: this starts at zero velocity because nothing was moving, while a
  /// settle continues a gesture. [motion] overrides [PanelConfig.motion] for
  /// this one animation.
  ///
  /// DESIGN.md §2.4 types the override as a `SpringDescription`. It is a
  /// [PanelMotion] here for the reason `motion.dart` gives for existing at all:
  /// `SpringDescription` has no `==`, and a panel whose motion is configured per
  /// placement, per page and per route needs its motion to be comparable.
  void animateTo(Detent detent, {PanelMotion? motion}) =>
      _settle(detent, motion: motion, velocity: ExtentVelocity.zero);

  /// The one place a settle is decided: which height, which spring, which seed.
  ///
  /// [velocity] defaults to whatever the panel is already doing, which is what
  /// makes a settle installed over a running one pick the motion up rather than
  /// restart it. [within] replaces the spring's duration and keeps its bounce,
  /// so a shortened settle is the same spring in less time.
  void _settle(
    Detent detent, {
    Duration? within,
    PanelMotion? motion,
    ExtentVelocity? velocity,
    bool notify = true,
  }) {
    final shape = motion ?? _config.motion;
    _settleAt(
      detent,
      // A detent that is not in the resolved set went inactive under the panel,
      // and the answer is `HoldDetent`'s, through the same expression it uses.
      heightOf(detent, _extent, _detents),
      velocity: velocity ?? _activity.velocity,
      motion: within == null
          ? shape
          : PanelMotion(duration: within, bounce: shape.bounce),
      notify: notify,
    );
  }

  /// The spring a re-seed continues.
  ///
  /// The running settle's own, so that shortening a settle does not also reshape
  /// it: `animateTo(motion: const PanelMotion.bouncy())` installs a spring the
  /// config does not have, and a correction that re-seeded out of
  /// [PanelConfig.motion] would keep the time and replace the curve — which is
  /// the opposite of what "the same spring in less time" claims.
  PanelMotion get _runningShape {
    final activity = _activity;
    return activity is SettlingPanelActivity ? activity.motion : _config.motion;
  }

  /// Installs the settle, or parks instead when there is no motion to make.
  ///
  /// The two refusals are the same refusal: a spring with nothing to do never
  /// reports itself done, so it would leave `isTicking` false with a settle
  /// installed — a panel that has stopped moving and is still, formally, moving.
  /// A driver reading [isTicking] stops driving, and nothing ever parks it.
  ///
  /// What decides the first refusal is the settle's **own** answer, asked before
  /// it is installed, rather than a second opinion written here. `velocity ==
  /// ExtentVelocity.zero` was one comparison too narrow by exactly the width of
  /// the simulation's own velocity tolerance: a release of 0.05 px/s onto the
  /// detent the panel is already standing on is an arrival that the exact
  /// comparison called a motion, and installed a settle that was done at t = 0
  /// and so was never ticked again. A gesture recogniser reports sub-pixel-per-
  /// second lifts routinely, for a finger that stops before it leaves.
  ///
  /// The second refusal is the whole sub-millisecond band and not just zero. See
  /// [kMinimumSettleDuration]: below it there is no spring to build, and asking
  /// for one throws from inside a layout pass in debug and hands the panel `NaN`
  /// forever in release. It is checked before the settle is built, because
  /// building it is what would throw.
  void _settleAt(
    Detent detent,
    Extent to, {
    required ExtentVelocity velocity,
    required PanelMotion motion,
    bool notify = true,
  }) {
    if (motion.duration >= kMinimumSettleDuration) {
      final settling = SettlingPanelActivity(
        destination: detent,
        from: _extent,
        to: to,
        velocity: velocity,
        motion: motion,
        // Half a physical pixel of the display this panel is actually on, which
        // is the finest difference it can show and therefore the last one worth
        // animating.
        tolerance: 0.5 / _layout.devicePixelRatio,
      );
      if (settling.isTicking) {
        _begin(settling, notify: notify);
        return;
      }
    }
    _begin(IdlePanelActivity(target: detent), notify: notify);
  }

  /// Advances [activity] by [delta], the time since the previous frame.
  ///
  /// Called by whatever owns the ticker, which reads [isTicking] to know when to
  /// stop. There is deliberately no guard on [isTicking] here. The one there
  /// used to be bought nothing — every leaf that does not want frames ignores
  /// the delta anyway, so it saved a call — and cost the one thing that can go
  /// wrong with a guard like it: an activity that does not want frames is not
  /// an activity with nothing left to do, and a settle installed with its spring
  /// already finished is handed the frame it parks the panel in *here*. Refuse
  /// that frame and it never asks for another, so nothing else arrives either —
  /// [isTicking] false with a settle installed, for the life of the panel.
  void tick(Duration delta) => _activity.tick(delta);

  /// Writes [next] and notifies if it moved. The writer every motion goes
  /// through.
  ///
  /// Activities live in another library and so cannot reach a private field;
  /// this is the one door, and it being the only one is what makes "the extent
  /// is one scalar owned by one model and animated by one thing" checkable
  /// rather than asserted. The two writes that do not come through here are the
  /// layout commit and [arriveAt], and both are single events that notify once
  /// for themselves.
  @internal
  void applyExtent(Extent next) {
    if (next == _extent) return;
    _extent = next;
    notifyListeners();
  }

  /// The last write of a settle and its parking, as one event.
  ///
  /// Two things happen and one notification goes out. `applyExtent` followed by
  /// [goIdle] fires two, so the final frame of every settle notified twice where
  /// every other frame notified once — and a listener that rebuilds on each does
  /// the work of a frame twice, in the frame a route, a barrier and a scroll
  /// link are all already reacting to. `_begin`'s `notify` parameter exists for
  /// exactly this.
  ///
  /// [at] is written whether or not it moved, because the activity changed
  /// regardless and the notification is going out either way.
  @internal
  void arriveAt(Extent at, {required Detent target}) {
    _extent = at;
    _begin(IdlePanelActivity(target: target), notify: false);
    notifyListeners();
  }

  /// Records the velocity a dismissal left with, for the route to pick up.
  ///
  /// Nothing calls this in this slice — dismissal is not in it — and the pair
  /// exists anyway because the alternative is a [takeExitVelocity] that can only
  /// ever answer zero, which is harder to find later than a seam with both ends
  /// named.
  @internal
  void stashExitVelocity(ExtentVelocity velocity) => _exitVelocity = velocity;
  ExtentVelocity _exitVelocity = ExtentVelocity.zero;

  /// The stashed exit velocity, cleared by the read.
  ///
  /// Consumed once, so a later programmatic pop cannot inherit a stale fling and
  /// animate away at the speed of a gesture that happened minutes ago.
  /// [ExtentVelocity.zero] when nothing was stashed.
  ExtentVelocity takeExitVelocity() {
    final velocity = _exitVelocity;
    _exitVelocity = ExtentVelocity.zero;
    return velocity;
  }

  /// Disposes the current activity and then the notifier.
  ///
  /// The one body in this file that is written rather than deferred, because
  /// there is no decision in it: the order is the only thing that matters and it
  /// is forced — an activity that outlived its model would tick into a disposed
  /// notifier.
  @override
  void dispose() {
    activity.dispose();
    super.dispose();
  }
}
