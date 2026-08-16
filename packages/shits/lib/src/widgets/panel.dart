/// The panel itself: the widget an app writes, and the one thing that assembles
/// every layer under it into a sheet.
///
/// This is the last piece of the first slice, and what it completes is the
/// slice's acceptance — *a single non-paged bottom sheet with three detents and
/// a bare `ListView`, dragged and flung*. Five things arrive here, each already
/// decided by something underneath:
///
/// 1. **The ticker.** `PanelModel` deliberately owns none: `TickerProvider` is
///    `scheduler.dart`, which carries a binding, and the layering rule in
///    DESIGN.md §6 is what keeps every test under `test/model/` a plain `test`
///    with no pump and no fake async. So a widget holds the `Ticker` and calls
///    `PanelModel.tick` with a **frame delta** — and the widget that holds it is
///    [PanelScrollAttachment], which this one installs. See [_PanelState] for
///    why the clock is one layer lower than DESIGN.md §6 files it, and for the
///    single-line change that moves it back.
/// 2. **The position, published continuously.** `PanelScope` and
///    `PanelController`; see `scope.dart` for why a resting detent is not
///    enough.
/// 3. **A content scaffold with a bar slot.** `PanelContentScaffold`, which
///    reads the position this widget publishes.
/// 4. **A `MediaQuery` the content can trust.** [PanelMediaQuery], installed
///    over the content, because the screen's insets stop describing the content
///    the moment the panel is not full height (A6.6).
/// 5. **The scroll layer, installed by the panel and not by the app.**
///    [PanelScrollAttachment], with no wrapper and no configuration object.
///
/// **The model is created here because its lifetime is this widget's.** A
/// `PanelModel` holds a running settle and a gesture's accumulated position, so
/// it outlives any one build and cannot be a value; `PanelViewport` takes one
/// rather than making one for exactly that reason. What creates it is whoever
/// owns the panel's lifetime, and for a non-modal panel that is this.
library;

import 'package:flutter/widgets.dart';

import '../geometry/anchor.dart';
import '../geometry/baseline.dart';
import '../geometry/detent.dart';
import '../geometry/detent_set.dart';
import '../geometry/layout.dart';
import '../model/panel_model.dart';
import '../physics/momentum.dart';
import '../physics/motion.dart';
import '../physics/snap.dart';
import '../render/panel_viewport.dart';
import '../render/render_panel.dart';
import '../scroll/attachment.dart';
import '../scroll/link.dart';
import '../scroll/policy.dart';
import 'panel_media_query.dart';
import 'scope.dart';

/// The rubber band's marginal resistance a [Panel] uses unless it is told
/// otherwise.
///
/// `PanelConfig`'s own default, restated because a constructor default has to be
/// a constant expression and that one is written inline. It is a *name* here so
/// that the number appears once per file rather than once per call site, and
/// `test/widgets/panel_test.dart` holds the two equal — a duplicated constant
/// with nothing comparing it is how the two come to disagree.
const double kPanelBandResistance = 0.55;

/// A panel: a box that rests at one of [detents] and hands scrolling off to
/// dragging without being asked to.
///
/// ```dart
/// Panel(
///   detents: const DetentSet([
///     Detent.height(DetentValue(180)),
///     Detent.medium,
///     Detent.full,
///   ]),
///   initialDetent: Detent.medium,
///   // A plain ListView. No controller, no wrapper, no config object.
///   child: ListView.builder(
///     itemCount: 200,
///     itemBuilder: (context, i) => Text('row $i'),
///   ),
/// )
/// ```
///
/// **The tree it builds, outermost first, and why each layer is where it is:**
///
/// ```
/// PanelScope(controller)            // the position, published to everything below
///  └ PanelViewport(model)           // the height, decided in a render object
///     └ PanelScrollAttachment(link) // the PrimaryScrollController and behaviour
///        └ PanelMediaQuery          // insets re-measured against the panel's rect
///           └ child
/// ```
///
/// [PanelViewport] is above the attachment so that a scrollable in the content
/// is laid out inside the panel's frame — which is what makes an inner
/// `ListView`'s `viewportDimension` the panel's *visible* extent rather than its
/// largest detent, and is the user-visible half of the render layer's
/// frame-based geometry. [PanelMediaQuery] is innermost so the insets it
/// publishes describe exactly the box the content is in.
///
/// **The panel is not a route.** It has no barrier, no dismissal and no entry
/// transition; `EdgeOffset` is pinned at zero underneath it. Those arrive with
/// `PanelRoute`, and this widget is what that route will put inside itself —
/// which is the reason it is built first and separately.
///
/// **What can drag it, in this slice.** A scrollable in the content, through
/// the scroll layer, with no opt-in. There is no gesture recogniser here: a
/// panel whose content has no scrollable in it cannot be dragged at all yet.
/// `DragPanelActivity` and `PanelDragMechanics` exist in the model for the
/// grabber and for a draggable background, and `widgets/handle.dart` is what
/// installs them.
class Panel extends StatefulWidget {
  /// Creates a panel resting at one of [detents], with [child] inside it.
  ///
  /// **Flattened rather than taking a `PanelConfig`**, because this is the
  /// package's front door and an author should be able to write a sheet without
  /// meeting a configuration type first. The config is assembled in
  /// [State.didUpdateWidget] and adopted through `PanelModel.updateConfig`,
  /// whose value equality is what makes rebuilding one per rebuild free — a
  /// config that compared unequal each time would re-resolve the detents and
  /// snap the panel on every frame, which is G10 read from the wrong end.
  const Panel({
    super.key,
    required this.detents,
    required this.child,
    this.initialDetent,
    this.controller,
    this.anchor = PanelAnchor.bottom,
    this.attachment = EdgeAttachment.edgeAttached,
    this.sizing = PanelSizing.resize,
    this.motion = const PanelMotion.smooth(),
    this.snapPolicy = SnapPolicy.projected,
    this.resnapWindow = kResnapWindow,
    this.bandResistance = kPanelBandResistance,
    this.scrollPolicy = PanelScrollPolicy.resizesFromEdge,
    this.refreshPolicy = PanelRefreshPolicy.whenFullyOpen,
    this.momentumCarry = MomentumCarry.both,
  });

  /// The heights this panel may rest at, in authoring order.
  ///
  /// A value type, so writing the set inline in `build` costs nothing: an
  /// equal set is not a set change and does not re-snap.
  final DetentSet detents;

  /// The panel's content.
  ///
  /// Constructed by the caller's `build` and therefore *above* this widget, but
  /// built by an element *below* it — so `PanelScope.of` and
  /// `PanelScope.metricsOf` resolve from inside it with no builder needed.
  final Widget child;

  /// Which of [detents] to open at, or null for the smallest active one.
  ///
  /// The detent and not the height. A panel opened at `Detent.medium` on a phone
  /// already on its side — where iOS deactivates medium — opens at the nearest
  /// surviving stop and moves to 469.68 the moment the phone is turned upright,
  /// because the *named* detent is what is remembered.
  final Detent? initialDetent;

  /// The app's handle on this panel, or null to have the panel make one.
  ///
  /// A controller the app made is the app's to dispose. One the panel made is
  /// disposed with the panel. Either way the content can reach it through
  /// `PanelScope.of`, so nothing has to be threaded through an app for a sheet
  /// to work.
  final PanelController? controller;

  /// Where the panel is attached, and therefore which way it grows.
  ///
  /// [PanelAnchor.bottom] is the only one with a rect in this slice; the other
  /// four refuse loudly from `PanelAnchor.rectOf` rather than guessing a cross
  /// axis.
  final PanelAnchor anchor;

  /// Whether the panel sits against its attachment edge or clear of it.
  final EdgeAttachment attachment;

  /// What a detent change moves — the frame, or the frame's position.
  final PanelSizing sizing;

  /// The spring every settle uses unless a correction shortens it.
  final PanelMotion motion;

  /// How far a single fling may travel through [detents].
  final SnapPolicy snapPolicy;

  /// How long a fling keeps re-choosing its landing after the layout changes
  /// under it.
  final Duration resnapWindow;

  /// The rubber band's marginal resistance at zero overshoot.
  final double bandResistance;

  /// Who gets a drag delta: the panel, or the scrollable it came from.
  final PanelScrollPolicy scrollPolicy;

  /// Who gets a downward drag from the content's own start — the panel, or a
  /// `RefreshIndicator`.
  final PanelRefreshPolicy refreshPolicy;

  /// What a fling does when it crosses the seam between the list and the panel.
  final MomentumCarry momentumCarry;

  @override
  State<Panel> createState() => _PanelState();
}

/// The panel's parts, named.
///
/// Its members carry no underscore because the class already does: `_PanelState`
/// is private, so everything on it is package-private whatever it is called, and
/// the parts of a panel are worth being able to name in a doc without the
/// punctuation. `_PanelScrollAttachmentState.controller` next door is the same
/// shape.
///
/// ---
///
/// **Where the clock is, and why it is not here.**
///
/// DESIGN.md §6 gives the `Ticker` to this file, and the argument for that is
/// sound: `PanelModel` owns no `TickerProvider`, so something in the widget
/// layer has to advance it, and the panel is what owns the model's lifetime.
/// `scroll/attachment.dart` holds one anyway, under a doc that says exactly why
/// — *"DESIGN.md gives this to `lib/src/widgets/panel.dart`, which does not
/// exist yet, and something has to hold it"* — with precisely the gate, the
/// frame delta and the post-tick stop this file was specified to have.
///
/// **The two must not both exist.** A panel installs the attachment, so a second
/// ticker here would start beside it on the same gate, `PanelModel.tick` would
/// be called twice a frame, and every settle would run at double the speed it
/// was asked for while reporting the duration it was asked for.
/// `test/widgets/panel_test.dart`'s `is one ticker for one settle, not two` is
/// the row that measures it, and falsification criterion 4 — *one simulation,
/// one ticker* — is the same claim from the fling's end.
///
/// So this layer adds none, and the package still has exactly one clock,
/// installed by the panel and gated on `SelfDrivenActivity`. What is lost is
/// only the *file* the design named. Moving it back is three deletions and a
/// move, all of them outside this directory: drop `_ticker`, `_elapsed`,
/// `_needsFrames`, `_activityChanged` and `_tick` from `scroll/attachment.dart`,
/// move `test/scroll/attachment_test.dart`'s *"the clock a self-driven motion
/// runs on"* group into `test/widgets/` — it pins the behaviour, not the widget
/// — and give this `State` a `SingleTickerProviderStateMixin` back. Until then
/// the behaviour is right and the address is wrong, which is the better of the
/// two ways to be inconsistent with a document.
class _PanelState extends State<Panel> {
  /// The two scalars this panel is, and the activity moving them.
  ///
  /// Null until [didChangeDependencies] has a `MediaQuery` to build a
  /// provisional layout from, because `PanelModel`'s constructor needs a
  /// `PanelLayout` and [initState] has no inherited state to read.
  ///
  /// **The provisional layout never reaches the screen, and that is a property
  /// of the model rather than a hope.** A panel's real viewport is its own
  /// constraints — not `MediaQuery.sizeOf`, which is the window and is wrong for
  /// a panel inside a `Padding`, a split view or a `SizedBox` — and only the
  /// render object knows those. But the model opens *at a detent* rather than at
  /// a height: its initial activity is `IdlePanelActivity(target:)`, whose
  /// correction is `LayoutCorrection.hold`, so the first `performLayout`
  /// re-resolves that detent against the real baseline and lays the child out at
  /// the answer. The provisional number is consumed by `dryApplyLayout` before
  /// anything is painted.
  ///
  /// What it *is* observable through is the first build: `PanelScope.metricsOf`
  /// answers out of the model, and the first build happens before the first
  /// layout. So content that positions itself off the metrics is provisional for
  /// exactly one frame on a panel whose box is not the window. The alternative —
  /// a `LayoutBuilder` above the model — buys that frame by rebuilding from
  /// inside a layout pass, which is the relayout-boundary claim the render layer
  /// is built on, spent on one frame.
  PanelModel? model;

  /// The arbiter every captured `ScrollPosition` holds.
  ///
  /// Created here rather than in [PanelScrollAttachment] because it has the
  /// model's lifetime and not the attachment's: it holds the position registry
  /// and the escape reports, and one recreated on a rebuild would drop both.
  /// Its three policies are **mutable fields** for the same reason — a panel
  /// rebuilt with a different `scrollPolicy` assigns it rather than replacing
  /// the link, so a policy change never detaches a live drag.
  PanelScrollLink? link;

  /// The handle published to the content and to the app.
  ///
  /// `widget.controller` when the app supplied one, and a private one otherwise.
  /// [ownsController] is what decides who disposes it.
  late PanelController controller;

  /// Whether [controller] is this state's to dispose.
  ///
  /// `late` and not initialised to `false`, because the two are written as a
  /// pair by [adoptController] and an initial value here would be a fourth
  /// place that could disagree with the other three — and one nothing reads,
  /// so nothing would say so.
  late bool ownsController;

  /// Adopts or creates the controller — the one part of a panel that needs no
  /// inherited state.
  @override
  void initState() {
    super.initState();
    adoptController(widget.controller);
  }

  /// Takes [supplied] as the handle, or makes one, and records who disposes it.
  ///
  /// The two call sites — [initState] and [didUpdateWidget] — must agree about
  /// [ownsController] or the app's controller is disposed under it, so the pair
  /// is written once.
  void adoptController(PanelController? supplied) {
    controller = supplied ?? PanelController();
    ownsController = supplied == null;
  }

  /// Creates the model, the link and the controller binding on the first call,
  /// and adopts a changed `MediaQuery` on every one after it.
  ///
  /// The model is built here rather than in [initState] because
  /// [PanelLayout] needs a `MediaQuery`, and it is built **once**: this runs
  /// again for every ancestor dependency change — a rotation, a keyboard, a
  /// theme — and a model rebuilt on any of those would drop the panel's height,
  /// its activity and its gesture. The changed geometry reaches the model
  /// through the layout pass, which is the one path that exists.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (model != null) return;

    final created = PanelModel(
      config: configOf(widget),
      layout: provisionalLayout(context),
    );
    model = created;
    link = PanelScrollLink(
      model: created,
      anchor: widget.anchor,
      scrollPolicy: widget.scrollPolicy,
      refreshPolicy: widget.refreshPolicy,
      momentumCarry: widget.momentumCarry,
    );
    controller.attach(created, anchor: widget.anchor);
  }

  /// Adopts a changed configuration without interrupting anything.
  ///
  /// Three separate adoptions, in order of how much they can disturb:
  ///
  /// - **The config**, through `PanelModel.updateConfig`, which is where G10
  ///   lives: an equal config is a no-op, and a genuinely changed detent set
  ///   settles the panel to the nearest surviving stop rather than jumping it.
  ///   The equality is why a `DetentSet` written inline in an app's `build` is
  ///   free.
  /// - **The link's policies**, by assignment. They are fields precisely so a
  ///   placement or a policy change does not recreate the link and detach every
  ///   registered position with it.
  /// - **The controller**, if the app swapped one in: detach the old, attach the
  ///   new, and dispose the old only if this state made it.
  @override
  void didUpdateWidget(Panel oldWidget) {
    super.didUpdateWidget(oldWidget);

    model!.updateConfig(configOf(widget));

    link!
      ..anchor = widget.anchor
      ..scrollPolicy = widget.scrollPolicy
      ..refreshPolicy = widget.refreshPolicy
      ..momentumCarry = widget.momentumCarry;

    if (widget.controller == oldWidget.controller) return;
    final outgoing = controller;
    final outgoingWasOurs = ownsController;
    outgoing.detach();
    adoptController(widget.controller);
    controller.attach(model!, anchor: widget.anchor);
    // Last, and only if this state made it. Disposing first would notify a
    // controller in the middle of being replaced, and disposing one the app
    // made would throw from the app's own `dispose` a frame later, with
    // nothing in the message naming the panel that did it.
    if (outgoingWasOurs) outgoing.dispose();
  }

  /// Tears the panel down in the one order that works.
  ///
  /// The link first, which ends any drag it installed and hands a scroll-driven
  /// activity back to a self-driven settle — that notifies, so it has to happen
  /// while the model is still alive. Then the controller's detach, then the
  /// model. A controller the app owns is detached and not disposed.
  ///
  /// The clock is not in this list and does not need to be: it belongs to
  /// [PanelScrollAttachment], which is a *descendant* of this element, and
  /// `BuildOwner.finalizeTree` unmounts children before their parents. So the
  /// ticker is disposed and its listener removed before this runs, and nothing
  /// ever advances a model that is being taken apart.
  @override
  void dispose() {
    link?.dispose();
    controller.detach();
    if (ownsController) controller.dispose();
    model?.dispose();
    super.dispose();
  }

  /// The layout the model is constructed with, before anything has been laid
  /// out.
  ///
  /// The window, from `MediaQuery`, and it is deliberately the *wrong* viewport
  /// for a panel that is not the whole route — see [model] for why being wrong
  /// here costs nothing. It reads `viewPaddingOf` and never `paddingOf`, for the
  /// reason `panel_viewport.dart` gives at length: padding collapses toward zero
  /// with the keyboard up while `viewPadding.bottom` keeps its 34pt, so a panel
  /// reading the wrong one loses 34pt off every detent the moment a field is
  /// focused.
  PanelLayout provisionalLayout(BuildContext context) {
    final textDirection = Directionality.of(context);
    return PanelLayout(
      baseline: PanelBaseline.from(
        viewport: MediaQuery.sizeOf(context),
        viewPadding: MediaQuery.viewPaddingOf(context),
        anchor: widget.anchor,
        textDirection: textDirection,
        attachment: widget.attachment,
      ),
      viewInsets: MediaQuery.viewInsetsOf(context),
      // Null, and not a measurement: only a content-sized detent asks for one
      // and this slice ships none. `DetentSet.needsContentMeasure` is the seam
      // that will decide it, and it does not exist yet — the same stand-in
      // `render_panel.dart` documents for `PanelViewport.measuresContent`.
      contentExtent: null,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      textDirection: textDirection,
    );
  }

  /// [Panel]'s flattened arguments, assembled into the value the model adopts.
  PanelConfig configOf(Panel widget) => PanelConfig(
    detents: widget.detents,
    initialDetent: widget.initialDetent,
    snapPolicy: widget.snapPolicy,
    motion: widget.motion,
    resnapWindow: widget.resnapWindow,
    bandResistance: widget.bandResistance,
  );

  /// The tree in the class doc, and nothing else.
  ///
  /// Written rather than deferred because the ordering is the specification and
  /// it is already argued above: [PanelViewport] over [PanelScrollAttachment],
  /// so a scrollable in the content is laid out inside the panel's frame and
  /// its viewport is the panel's *visible* extent; [PanelMediaQuery] innermost,
  /// so the insets it publishes describe the box the content is actually in.
  ///
  /// It reads no metrics. A panel that rebuilt this on every notification would
  /// rebuild [PanelViewport] and [PanelScrollAttachment] sixty times a second
  /// to hand them the same two objects — the model reaches the render object as
  /// a listener and the position reaches the content through [PanelScope], and
  /// neither of those is a build.
  @override
  Widget build(BuildContext context) => PanelScope(
    controller: controller,
    child: PanelViewport(
      model: model!,
      anchor: widget.anchor,
      attachment: widget.attachment,
      sizing: widget.sizing,
      child: PanelScrollAttachment(
        link: link!,
        child: PanelMediaQuery(child: widget.child),
      ),
    ),
  );
}
