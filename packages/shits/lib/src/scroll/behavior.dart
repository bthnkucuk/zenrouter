/// The coverage backstop: the channel that reaches **every** scrollable in the
/// panel, including the ones the controller cannot.
///
/// `PrimaryScrollController` misses four kinds of scrollable — one that brought
/// its own `controller:`, one with `primary: false`, a bare `Scrollable`, and one
/// whose axis does not match — and `capture_test.dart` measures all four.
/// `ScrollBehavior` misses none of them: `scrollable.dart:618` is
/// `_configuration = widget.scrollBehavior ?? ScrollConfiguration.of(context)`,
/// unconditional in `didChangeDependencies`, with no `primary` gate, no
/// controller gate and no platform gate.
///
/// So this is design A's mechanism kept for the job it is actually best at.
/// Detection is **synchronous, on the first delta, with the position in hand and
/// the widget nameable** — where a `ScrollMetricsNotification` listener fires a
/// frame late, needs a `depth` filter, and has no position to name. It is not the
/// arbiter: the split lives in `PanelScrollPosition`, where a user-supplied
/// `physics:` cannot shadow it.
///
/// `scroll_configuration.dart:415-418` plus a `shouldNotify` over a long-lived
/// link means installing this causes no position churn — a `ScrollConfiguration`
/// whose behaviour compares equal does not rebuild the scrollables under it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'link.dart';
import 'position.dart';

/// Wraps the ambient `ScrollBehavior`, replacing only its physics.
///
/// Every other member forwards to [inner], and that is not laziness: a
/// `ScrollBehavior` decides the platform, the drag devices, the overscroll
/// indicator, the scrollbar and the keyboard-dismiss behaviour, and a panel has
/// an opinion about exactly one of them. Substituting a fresh `ScrollBehavior`
/// instead of wrapping would silently discard whatever the app configured — a
/// `MaterialScrollBehavior` with a themed scrollbar, or a desktop app that added
/// `PointerDeviceKind.mouse` to `dragDevices` — and the loss would look like a
/// theming bug three screens away.
class PanelScrollBehavior extends ScrollBehavior {
  /// Wraps [inner], arbitrating through [link].
  const PanelScrollBehavior({required this.inner, required this.link});

  /// The behaviour this one was installed over — `ScrollConfiguration.of` at the
  /// panel's root.
  final ScrollBehavior inner;

  /// The arbiter the physics reports escapes to.
  final PanelScrollLink link;

  /// [inner]'s physics with [PanelScrollPhysics] on the outside.
  ///
  /// Outside rather than inside, so that the escape check runs before anything
  /// else transforms the offset. It delegates to [inner] for a position of ours,
  /// so a `ScrollConfiguration` that asked for clamping physics still gets
  /// clamping physics — the panel replaces the *detector*, not the feel.
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      PanelScrollPhysics(link: link, parent: inner.getScrollPhysics(context));

  /// Forwards to [inner].
  ///
  /// **DESIGN.md §3.4 puts a debug registrar here and this slice does not ship
  /// one.** The argument for it is sound: `scrollable.dart:995-1006` calls this
  /// with `ScrollableDetails(controller: _effectiveScrollController)` for
  /// **every** scrollable, including one that fell back to its own private
  /// controller, so it is the only channel that can see a position which escaped
  /// the controller *and* set its own `physics:` — the residual hole
  /// [PanelScrollPhysics] cannot cover.
  ///
  /// What it would have to do is the problem. The information available here is
  /// a controller and a `BuildContext`, and both are available at *build* time —
  /// so a detector written from them fires while the tree is being built, where
  /// every correct case ([PanelScrollLink.isEscape]'s three exemptions) fires
  /// too and one frame earlier than the one net that can tell them apart. A
  /// detector that catches the fourth case by complaining about the three
  /// correct ones is worse than the hole; the honest version watches a
  /// registered position's pixels move across a frame without our physics having
  /// been consulted, which is per-frame machinery and a false-positive surface,
  /// and it is not written here because nothing tests it.
  ///
  /// So the hole stands, named twice — here and on [PanelScrollPhysics] — rather
  /// than being covered by something unexercised.
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => inner.buildOverscrollIndicator(context, child, details);

  /// Forwards to [inner].
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => inner.buildScrollbar(context, child, details);

  /// Forwards to [inner].
  @override
  TargetPlatform getPlatform(BuildContext context) =>
      inner.getPlatform(context);

  /// Forwards to [inner].
  @override
  Set<PointerDeviceKind> get dragDevices => inner.dragDevices;

  /// Forwards to [inner].
  @override
  MultitouchDragStrategy getMultitouchDragStrategy(BuildContext context) =>
      inner.getMultitouchDragStrategy(context);

  /// Forwards to [inner].
  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
    BuildContext context,
  ) => inner.getKeyboardDismissBehavior(context);

  /// True only when the link or the wrapped behaviour actually changed.
  ///
  /// The link is long-lived — one per panel, surviving every rebuild of the
  /// widget that installs it — so this is false on an ordinary rebuild, and
  /// `scroll_configuration.dart:415-418` therefore does not rebuild the
  /// scrollables underneath. Returning true unconditionally would recreate every
  /// `ScrollPosition` in the panel on every frame of a drag, which is the
  /// opposite of what owning the position bought.
  @override
  bool shouldNotify(covariant PanelScrollBehavior oldDelegate) =>
      !identical(oldDelegate.link, link) || oldDelegate.inner != inner;

  @override
  String toString() => 'PanelScrollBehavior($inner)';
}

/// Physics that asks one question: is this position one of ours?
///
/// If yes, the split already happened in `PanelScrollPosition.drag` and this
/// passes straight through to [parent]. If no, the scrollable escaped capture,
/// and this is the moment we know — synchronously, on the first delta, with the
/// position in hand.
///
/// **It is a detector and not a mechanism, and the distinction is the whole
/// reason the arbitration is somewhere else.** `scroll_physics.dart:710-716`
/// shows `BouncingScrollPhysics.applyPhysicsToUserOffset` not delegating to its
/// parent, and `scrollable.dart:622` applies a widget's own physics outermost —
/// so `ListView(physics: BouncingScrollPhysics())` removes this class from the
/// chain entirely. A design that split here would be silently disabled by one
/// constructor argument. A design that only *detects* here loses one detection,
/// which is a hole with a second net rather than a failure.
class PanelScrollPhysics extends ScrollPhysics {
  /// Detects escapes for [link], over [parent].
  const PanelScrollPhysics({required this.link, super.parent});

  /// The arbiter that owns the registry and decides what an escape is.
  final PanelScrollLink link;

  /// Rebuilds this physics over [ancestor], keeping [link].
  ///
  /// Required by `ScrollPhysics.applyTo`'s contract, and a
  /// `ScrollPhysics.applyTo` that dropped a field is the commonest way a custom
  /// physics stops working when someone adds `physics:` above it — the object is
  /// rebuilt through this method every time the chain is composed.
  @override
  PanelScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      PanelScrollPhysics(link: link, parent: buildParent(ancestor));

  /// Passes an owned position's offset through, and complains about anyone
  /// else's.
  ///
  /// Four outcomes:
  ///
  /// 1. A `PanelScrollPosition` of **this** link → `super`. Arbitration already
  ///    happened; adding anything here would apply the split twice.
  /// 2. `link.isEscape(position)` is false → `super`, silently. An axis
  ///    mismatch, a nested inner list, a text field's own scrollable and a list
  ///    that escaped inside a *different* panel all land here, and all of them
  ///    are behaviour to leave alone.
  /// 3. An escape that is a `PanelScrollPosition` of another link →
  ///    `link.reportEscape(position)`, then `super`. It has an arbiter; it is
  ///    the wrong one. See below.
  /// 4. Anything else → `reportEscape`, then
  ///    `link.degradedSplit(position, offset)` for the release build's
  ///    drag-time-only split.
  ///
  /// **The first test is the link and not the type, and that is the difference
  /// between two rows.** A bare `position is PanelScrollPosition` returns before
  /// [PanelScrollLink.isEscape] is ever asked, which makes that method's own
  /// first exemption — *"a `PanelScrollPosition` belonging to a **different**
  /// panel … is an escape from this one's point of view"* — unreachable through
  /// the only channel that calls it. A list inside this panel holding another
  /// panel's `PanelScrollController` then drags the sheet it is not in while
  /// this one stands still, which is the same symptom as no capture at all and
  /// is exactly what the report exists to name.
  ///
  /// **It is reported and not driven**, which is where it parts company with
  /// outcome 4. [PanelScrollLink.degradedSplit] exists because an escapee has no
  /// arbiter; this one has one, so a second would move two sheets with one
  /// finger — a worse failure than the silent one, and in release, where nothing
  /// throws to say why.
  ///
  /// This method is reached from `ScrollPositionWithSingleContext.applyUserOffset`
  /// (`:131`), which has exactly two callers in the framework — that one and
  /// `nested_scroll_view.dart:1308` — so an escapee inside a `NestedScrollView`
  /// is seen through the same door.
  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // Ours: the split already happened in `PanelScrollPosition.applyUserOffset`,
    // and doing anything here would apply it twice. The link and not the type,
    // or a position arbitrating for a *different* panel is waved through as one
    // of ours and the mistake is silent.
    if (position is PanelScrollPosition && identical(position.link, link)) {
      return super.applyPhysicsToUserOffset(position, offset);
    }
    // Not ours, and correctly not ours — an axis mismatch, a nested inner list,
    // a text field's own scrollable, a list that escaped inside another panel.
    // All of them are behaviour to leave alone, and a detector that complained
    // about them would complain about a carousel in a sheet, which is the
    // commonest correct thing anyone puts in one.
    if (!link.isEscape(position)) {
      return super.applyPhysicsToUserOffset(position, offset);
    }
    link.reportEscape(position);
    // Already arbitrating, for the wrong panel. Told about, never driven: a
    // second arbiter on one position moves two sheets with one finger.
    if (position is PanelScrollPosition) {
      return super.applyPhysicsToUserOffset(position, offset);
    }
    return link.degradedSplit(position, offset);
  }

  @override
  String toString() => 'PanelScrollPhysics(parent: $parent)';
}
