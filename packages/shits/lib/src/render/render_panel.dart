/// The render object that gives a panel its size, and the ambient half of the
/// layout it needs to compute one.
///
/// **Named `RenderPanelViewport`, in a file DESIGN.md §6 calls `render_panel.dart`.**
/// The document disagrees with itself: the graft note that argues the perf case
/// ("Grafted from B", item 3) calls the class `RenderPanelViewport`, the §2.5
/// sketch calls it `RenderPanel`, and §6 files it under `render_panel.dart`. The
/// class takes the name from the note that gives the reason, and the file keeps
/// the name from the layout table, so nothing already written down has to be
/// wrong. `panel_viewport.dart` next door holds the *widget*, which is what §6
/// says it holds.
///
/// This file imports `package:flutter/rendering.dart` and deliberately not
/// `package:flutter/widgets.dart`, even though the wider import is on the
/// layer's allow-list and would cover it. Nothing here may reach a
/// `BuildContext`: the whole claim of this layer is that a panel resizes without
/// the widget tree hearing about it, and a file that can see `BuildContext` is a
/// file where someone can call `setState`. `test/architecture/imports_test.dart`
/// keeps that narrower than the layer.
library;

import 'package:flutter/rendering.dart';
import 'package:meta/meta.dart';

import '../geometry/anchor.dart';
import '../geometry/baseline.dart';
import '../geometry/layout.dart';
import '../geometry/units.dart';
import '../model/activity.dart';
import '../model/panel_model.dart';

/// What a detent change moves: the frame, or the frame's position.
///
/// DESIGN.md §2.5 declares this here rather than in `geometry/`, and that is
/// right: it is a policy about what the render object *does* with the extent the
/// model resolved, not about what the extent means. Nothing in `geometry/` or
/// `model/` branches on it.
///
/// This slice ships [resize] only. The other two are declared because they are
/// the reason the enum exists — `DismissalMode.shrink` re-expressed as a layout
/// policy — and because a missing arm of a `switch` is a compile error the day
/// they land, where a missing enum value is a silent redesign.
enum PanelSizing {
  /// The frame is the extent: the child is laid out at whatever the model
  /// resolved, every frame.
  ///
  /// The content's viewport therefore *is* the panel's visible span, which is
  /// what lets an inner `ListView` report a `viewportDimension` equal to the
  /// panel's height while the panel is still moving.
  resize,

  /// The frame is the largest detent, translated so that only the extent shows.
  ///
  /// The child is laid out once, at `detents.max`, and the panel moves it. That
  /// is cheaper and it is what a dismissal wants — content that does not reflow
  /// while it leaves — and it is why [Extent] and [EdgeOffset] are two types:
  /// under this policy the child's height and the panel's presence are different
  /// numbers at the same time.
  translate,

  /// [translate], with the part of the child outside the extent clipped away.
  clip,
}

/// The half of a [PanelLayout] that comes from the widget tree rather than from
/// the box.
///
/// A layout pass needs six things and the render object only knows one of them:
/// `constraints.biggest` is the viewport, and the view padding, the keyboard
/// inset, the pixel ratio and the reading direction all live in a `MediaQuery`
/// the render object cannot see. This carries those four down, and
/// [layoutFor] joins them to the viewport at the one moment both are known.
///
/// **A value type, and the equality is what makes it one field instead of four.**
/// `RenderPanelViewport` re-reads this on every rebuild of the widget above it;
/// four separate setters would be four chances to forget the `if (value == _x)
/// return` guard, and forgetting one means a `markNeedsLayout` on every rebuild
/// — which is the budget this layer is measured by, spent on a rebuild that
/// changed nothing.
///
/// **What it deliberately does not carry:** a `Size`. The viewport is the panel's
/// own constraints, not `MediaQuery.sizeOf`, because a panel inside a split view
/// or a `Padding` is smaller than the window and a baseline measured against the
/// window would put its `.full` detent off the bottom of its own box. The known
/// limit of that choice: the view padding is still the *window's*, so a panel
/// that does not reach the bottom of the screen absorbs a home indicator that is
/// not under it. Correcting that needs the panel's global rect, which is not
/// known during its own layout, and the first slice puts the panel over the whole
/// route.
@immutable
final class PanelMedia {
  /// Captures the ambient half of a layout pass.
  ///
  /// [viewPadding] must come from `MediaQuery.viewPaddingOf` and never from
  /// `paddingOf`. See [PanelBaseline] for what the substitution costs; the type
  /// cannot refuse it here, because both are `EdgeInsets`, so
  /// `panel_viewport.dart` is where the choice is made and
  /// `test/render/panel_viewport_test.dart` is where it is held.
  const PanelMedia({
    required this.viewPadding,
    required this.viewInsets,
    required this.devicePixelRatio,
    required this.textDirection,
  });

  /// `MediaQuery.viewPaddingOf` — the inset that keeps its 34pt with the
  /// keyboard up.
  final EdgeInsets viewPadding;

  /// `MediaQuery.viewInsetsOf` — the keyboard, and the only thing a keyboard
  /// policy reads.
  final EdgeInsets viewInsets;

  /// `MediaQuery.devicePixelRatioOf` — what half a physical pixel is worth.
  final double devicePixelRatio;

  /// `Directionality.of` — which edge is leading.
  final TextDirection textDirection;

  /// What detents resolve against, once the box knows how big it is.
  ///
  /// Split from [layoutFor] rather than folded into it because the baseline is
  /// needed *before* the layout can be finished: a content measurement is taken
  /// against the largest frame a detent could occupy and across the pinned
  /// cross span, both of which are baseline questions, and its answer is one of
  /// the layout's own fields. One call, one baseline, used twice — the
  /// alternative is deriving it once to measure and again to build, which is
  /// two chances for the panel to measure content against a geometry it does
  /// not then lay out in.
  PanelBaseline baselineFor(
    Size viewport, {
    required PanelAnchor anchor,
    required EdgeAttachment attachment,
  }) => PanelBaseline.from(
    viewport: viewport,
    viewPadding: viewPadding,
    anchor: anchor,
    textDirection: textDirection,
    attachment: attachment,
  );

  /// The whole layout pass.
  ///
  /// The one place a [PanelLayout] is constructed in this package outside a
  /// test. It is a method on the ambient half rather than a constructor on
  /// [PanelLayout] because half of what it needs — the baseline, and therefore
  /// the viewport — is what the widget tree does not have.
  ///
  /// [contentExtent] is required and nullable so that a caller has to say which
  /// case it is in: null means "nothing measured the content this pass", which
  /// is the ordinary case and not a missing value.
  PanelLayout layoutFor(
    PanelBaseline baseline, {
    required Extent? contentExtent,
  }) => PanelLayout(
    baseline: baseline,
    viewInsets: viewInsets,
    contentExtent: contentExtent,
    devicePixelRatio: devicePixelRatio,
    textDirection: textDirection,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PanelMedia &&
          other.viewPadding == viewPadding &&
          other.viewInsets == viewInsets &&
          other.devicePixelRatio == devicePixelRatio &&
          other.textDirection == textDirection;

  @override
  int get hashCode =>
      Object.hash(viewPadding, viewInsets, devicePixelRatio, textDirection);

  @override
  String toString() =>
      'PanelMedia(viewPadding: $viewPadding, viewInsets: $viewInsets, '
      'devicePixelRatio: $devicePixelRatio, '
      'textDirection: ${textDirection.name})';
}

/// The box that asks the model how big the panel is and lays the content out at
/// that answer.
///
/// Four things carry this class, and each is a decision with a reason:
///
/// **1. [sizedByParent] is true, and the child's constraints are tight.**
/// `rendering/object.dart:2847` is
/// `_isRelayoutBoundary = !parentUsesSize || sizedByParent || constraints.isTight || parent == null`.
/// So this box is a relayout boundary — a `markNeedsLayout` on every frame of a
/// drag never dirties the app tree above it — and the child is one too, so
/// content-internal layout never dirties this box. Both halves matter and
/// `test/render/render_panel_test.dart` holds each separately.
///
/// The downward half has one documented exception, and it is the exception that
/// makes a content detent possible at all: `RenderBox.markNeedsLayout`
/// (`rendering/box.dart:2856`) is
/// `if (_layoutCacheStorage.clear() && parent != null) { markParentNeedsLayout(); return; }`,
/// so once [measureContent] has asked the child for a dry layout, the child's
/// *next* dirty escalates to this box rather than stopping at it. That is
/// correct — a `Detent.content` could not update otherwise — and it is a
/// different budget under a different configuration: ten content-driven dirties
/// cost ten panel passes plus ten measures. [measuresContent] is a field and not
/// "measure always" for exactly that reason, and the two configurations are
/// tested apart.
///
/// Note that `BoxConstraints.isTight` is `hasTightWidth && hasTightHeight`
/// (`rendering/box.dart:377`), so the child's constraints are tight on **both**
/// axes and not only on the span axis. DESIGN.md §2.5 names its helper
/// `_tightOnSpanAxis`; taken literally that leaves `isTight` false and the second
/// half of the perf claim untrue. The cross axis is pinned at every detent
/// anyway — that is G8 — so tightening it costs nothing and buys the boundary.
///
/// **2. The extent comes from the model, once per layout.** [performLayout] asks
/// `model.dryApplyLayout` for the number it lays the child out at and
/// `model.applyLayout` to commit it. Those agree by construction — the model has
/// one `resolve` and no bypass — but this is the only place that calls both, so
/// it is the only place that could reintroduce a disagreement. The dry answer is
/// never cached across frames and never recomputed differently for painting.
///
/// **3. Content measurement is dry layout, never intrinsics.** See
/// [measureContent].
///
/// **4. One child layout per frame.** Nothing here lays the child out twice, and
/// nothing walks its intrinsics. `smooth_sheets` does both, every frame. The
/// budget is asserted rather than hoped for: the test harness counts a child's
/// own `performLayout` calls, because Flutter 3.44.9 has no `debugLayoutCount`
/// for it to read — DESIGN.md §2.5 cites one, and it does not exist.
class RenderPanelViewport extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  /// Creates the box for a panel driven by [model].
  ///
  /// Everything but [model] and [media] has a default, and the defaults are this
  /// slice: the bottom anchor, attached to its edge, resizing, measuring
  /// nothing.
  RenderPanelViewport({
    required PanelModel model,
    required PanelMedia media,
    PanelAnchor anchor = PanelAnchor.bottom,
    EdgeAttachment attachment = EdgeAttachment.edgeAttached,
    PanelSizing sizing = PanelSizing.resize,
    bool measuresContent = false,
    RenderBox? child,
  }) : _model = model,
       _media = media,
       _anchor = anchor,
       _attachment = attachment,
       _sizing = sizing,
       _measuresContent = measuresContent {
    this.child = child;
  }

  /// The two scalars this box lays out, and the activity moving them.
  ///
  /// Listened to rather than rebuilt from: a settle notifies once a frame, and
  /// the answer to a notification is a layout of this subtree, not a build of
  /// anything. That is the whole reason the model is a `ChangeNotifier` reaching
  /// a render object instead of a value reaching a widget.
  PanelModel get model => _model;
  PanelModel _model;
  set model(PanelModel value) {
    if (identical(value, _model)) return;
    if (attached) {
      _model.removeListener(_handleModelChanged);
      value.addListener(_handleModelChanged);
    }
    _model = value;
    markNeedsLayout();
  }

  /// The ambient half of the layout, re-read whenever the widget above rebuilds.
  PanelMedia get media => _media;
  PanelMedia _media;
  set media(PanelMedia value) {
    if (value == _media) return;
    _media = value;
    markNeedsLayout();
  }

  /// Where the panel is attached, and therefore which way it grows.
  ///
  /// Carried as its own field alongside [attachment] because `Placement` — which
  /// DESIGN.md §1.2 bundles the two into, along with `CrossAxisFit` and
  /// `anchorGap` — is not in this slice's file list and lives in `geometry/`,
  /// which this slice does not own. The two fields are what `Placement` replaces
  /// when it lands.
  PanelAnchor get anchor => _anchor;
  PanelAnchor _anchor;
  set anchor(PanelAnchor value) {
    if (value == _anchor) return;
    _anchor = value;
    markNeedsLayout();
  }

  /// Whether the panel sits against its attachment edge or clear of it.
  ///
  /// Reaches [PanelBaseline.attachedPadding], and so decides whether a
  /// `.height(200)` detent is a 234pt frame or a 200pt one.
  EdgeAttachment get attachment => _attachment;
  EdgeAttachment _attachment;
  set attachment(EdgeAttachment value) {
    if (value == _attachment) return;
    _attachment = value;
    markNeedsLayout();
  }

  /// What a detent change moves.
  ///
  /// [PanelSizing.resize] only in this slice; the other two refuse in
  /// [performLayout] rather than approximating, the way
  /// `PanelAnchor.rectOf` refuses the four anchors it does not ship.
  PanelSizing get sizing => _sizing;
  PanelSizing _sizing;
  set sizing(PanelSizing value) {
    if (value == _sizing) return;
    _sizing = value;
    markNeedsLayout();
  }

  /// Whether any detent needs the content measured this pass.
  ///
  /// **A stand-in for `DetentSet.needsContentMeasure`, and it says so.** The
  /// question belongs to the detent set — only it knows whether a
  /// `Detent.content` is in it — but `Detent.content` is not in this slice and
  /// `geometry/` is not this slice's to extend. So the render object is told,
  /// and when the detent lands this field becomes
  /// `model.config.detents.needsContentMeasure` and stops being a parameter.
  ///
  /// It is a field rather than "measure always" because a measure is a dry
  /// layout of the whole content subtree, and paying for one on every frame of
  /// every drag for a panel with no content detent is the two-layouts-per-frame
  /// cost this layer exists to avoid, bought back under a different name.
  bool get measuresContent => _measuresContent;
  bool _measuresContent;
  set measuresContent(bool value) {
    if (value == _measuresContent) return;
    _measuresContent = value;
    markNeedsLayout();
  }

  /// Where the panel sat after the last layout pass, in this box's coordinates.
  ///
  /// The rect the child was laid out at and painted at — one call to
  /// [PanelAnchor.rectOf], used for both, so the frame the content gets and the
  /// frame the user sees cannot drift apart. Reading it before the first layout
  /// throws, which is the right answer: there is no rect yet.
  ///
  /// Public because the widget layer's barrier, handle and hit-test surfaces all
  /// need to know where the panel is, and re-deriving it from `model.extent`
  /// would be the second copy of the geometry.
  Rect get panelRect {
    assert(
      _panelRect != null,
      'This panel has not been laid out yet, so it has no rect. Reading '
      'panelRect during a build reads it one frame early: the rect is written '
      'in performLayout, and a widget that needs it — a barrier, a handle — '
      'must be laid out by the panel rather than built beside it.',
    );
    return _panelRect!;
  }

  /// Null until the first [performLayout].
  ///
  /// Nullable rather than `late` so that [debugFillProperties] can say "not laid
  /// out yet" instead of throwing. A diagnostics method that throws turns a
  /// render-tree dump — which is what someone reaches for when a layout pass has
  /// already failed — into a second, unrelated failure on top of the first.
  Rect? _panelRect;

  /// Gives the child somewhere to keep its offset.
  ///
  /// A [BoxParentData] and not the default [ParentData]: the child is placed at
  /// [panelRect]'s corner rather than at this box's origin, and putting that
  /// offset where the framework expects it is what makes [applyPaintTransform]
  /// — and therefore `localToGlobal` from inside the panel, which the scroll
  /// layer needs — correct without a second transform written by hand.
  @override
  void setupParentData(covariant RenderObject child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _model.addListener(_handleModelChanged);
    // The model may have moved while this box was detached — a route being
    // rebuilt over a settle that never stopped. Nothing recorded that, so the
    // only safe assumption is that it did.
    markNeedsLayout();
  }

  @override
  void detach() {
    _model.removeListener(_handleModelChanged);
    super.detach();
  }

  /// Marks this box dirty when the panel moved, and does nothing when the panel
  /// moved *because of this box*.
  ///
  /// **The re-entrancy guard is the decision here, and without it this class does
  /// not work.** [performLayout] calls `model.applyLayout`, which notifies from
  /// inside the layout pass — that is the model's documented shape, one
  /// notification for the whole commit. Answering that notification with
  /// `markNeedsLayout` is calling it on the object currently being laid out, and
  /// `RenderObject.markNeedsLayout` asserts `_debugCanPerformMutations`:
  ///
  /// **The guard covers the whole pass and not only the commit**, because the
  /// window the paragraph above describes is the whole pass. `child.layout` and
  /// [measureContent] are both inside [performLayout] and both run arbitrary
  /// content code, and content that writes to the model from its own layout —
  /// `ScrollPosition.applyContentDimensions` and `correctPixels` have that
  /// shape, and the scroll layer is the next slice — produced the identical
  /// re-entrant `markNeedsLayout` from a place the narrower guard did not reach.
  /// What the framework said about it named the symptom: this box was mutated
  /// during its own layout. What was actually wrong is that the child had
  /// already been laid out at a height the model no longer agreed with, and
  /// [performLayout]'s own assert is what names *that*.
  ///
  /// > A RenderPanelViewport was mutated in its own performLayout
  /// > implementation. A RenderObject must not re-dirty itself while still being
  /// > laid out.
  ///
  /// In release the assert is gone and the framework mostly absorbs it —
  /// `layout` clears `_needsLayout` *after* `performLayout` returns, so the node
  /// is re-added to the owner's dirty list and then skipped — which is worse
  /// than a crash rather than better: the panel works, the budget looks clean,
  /// and only debug builds ever say anything.
  ///
  /// So the implementation sets a flag around the commit and this returns early
  /// while it is set. The notification is not news: this box is at that moment
  /// laying out the very answer being announced.
  ///
  /// **There is no "did it actually move" check here**, and there must not be.
  /// The model already has one — `applyExtent` returns without notifying when
  /// the extent is unchanged, and `applyLayout` notifies only when the layout,
  /// the detents, the extent or the activity moved — so a second guard here
  /// would be a second answer to the same question, and the two would disagree
  /// the first time a correction changed something this box did not think to
  /// compare. A frame where nothing moved costs zero layouts because nothing
  /// calls this, not because this declined.
  void _handleModelChanged() {
    if (_inLayout) return;
    markNeedsLayout();
  }

  /// True for the whole of [performLayout].
  ///
  /// The whole of the guard. It is a field on the box rather than a parameter
  /// threaded through the model because the model has no business knowing who
  /// is listening to it — the commit notifies once, for everyone, and this box
  /// is the one listener that already knows.
  bool _inLayout = false;

  /// True: the panel's own size is its constraints and nothing else.
  ///
  /// This is half of the perf claim. `rendering/object.dart:2847` makes a
  /// `sizedByParent` box a relayout boundary regardless of `parentUsesSize`, so
  /// the `markNeedsLayout` this box issues on every frame of a drag stops here
  /// and the app tree above never re-lays-out.
  ///
  /// It is also true in the plain sense: a panel fills the space it is given and
  /// paints a rect inside it. The child's height does not change this box's
  /// height — that is what makes the panel's own geometry invisible from
  /// outside.
  @override
  bool get sizedByParent => true;

  /// The constraints' largest size — the panel fills what it is given.
  ///
  /// Asserts both axes are bounded, for `RenderViewport`'s reason
  /// (`rendering/viewport.dart:1680-1683`): an unbounded constraint makes
  /// `biggest` infinite, and an infinite viewport span makes every detent
  /// infinite with it. A panel in a `Column` without an `Expanded` is the case,
  /// and it should say so rather than resolve `.medium` to infinity.
  ///
  /// The message must name a **detent**, and the test pins that rather than
  /// pinning the fact that something threw. Without our own refusal the
  /// framework still stops — `debugAssertDoesMeetConstraints` reports "was given
  /// an infinite size during layout" — but that names the symptom three layers
  /// below the mistake, and the mistake is the missing `Expanded`.
  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    assert(
      constraints.hasBoundedWidth && constraints.hasBoundedHeight,
      'A panel fills the space it is given, so an unbounded constraint makes '
      'its viewport infinite and every detent resolved against it infinite '
      'too. Give the panel a bounded box — an Expanded inside a Column, or a '
      'SizedBox — rather than letting .medium resolve to infinity.',
    );
    return constraints.biggest;
  }

  /// Refuses, for the same reason [computeDryLayout] refuses an unbounded axis.
  ///
  /// `RenderBox`'s defaults answer `0.0` for all four intrinsics, and a `0.0`
  /// from this box is not a small answer, it is a wrong one: an `IntrinsicHeight`
  /// — or anything else that sizes a child from its intrinsics — would hand the
  /// panel a *bounded*, tight zero, sail past [computeDryLayout]'s assert, and
  /// produce a zero-height panel laying its child out 34pt tall entirely above
  /// its own box. Measured, before this refusal existed:
  /// `tight 402×0 → panelSize=Size(402.0, 0.0) extent=34.0 rect=(0, −34, 402, 0)`.
  ///
  /// The shape is `RenderViewport.debugThrowIfNotCheckingIntrinsics`'s
  /// (`rendering/viewport.dart:705-749`), whose measurement behaviour this file
  /// already cites: throw from inside an assert unless
  /// `RenderObject.debugCheckingIntrinsics` is set, so `debugCheckIntrinsicSizes`
  /// can still walk the tree, and answer `0.0` in release.
  ///
  /// It is a refusal rather than an implementation because there is nothing
  /// honest to implement. A panel's height is its *detents'*, and a detent is
  /// resolved against a viewport the intrinsic protocol does not carry — the
  /// caller is asking how tall this box wants to be, and the answer depends on
  /// how tall the caller is going to let it be.
  bool _debugRefusesIntrinsics() {
    assert(() {
      if (!RenderObject.debugCheckingIntrinsics) {
        throw FlutterError.fromParts(<DiagnosticsNode>[
          ErrorSummary(
            '$runtimeType does not support returning intrinsic dimensions.',
          ),
          ErrorDescription(
            'A panel is as tall as the detent it is resting at, and a detent is '
            'resolved against the viewport the panel is given — which is what '
            'an intrinsic query has not decided yet. Answering one would mean '
            'answering before the question exists.',
          ),
          ErrorHint(
            'Give the panel a bounded box instead of asking it how big it wants '
            'to be: an Expanded inside a Column, or a SizedBox. A parent that '
            'sizes from intrinsics — IntrinsicHeight, IntrinsicWidth — hands the '
            'panel a tight zero and collapses it silently.',
          ),
        ]);
      }
      return true;
    }());
    return true;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    assert(_debugRefusesIntrinsics());
    return 0;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    assert(_debugRefusesIntrinsics());
    return 0;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    assert(_debugRefusesIntrinsics());
    return 0;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    assert(_debugRefusesIntrinsics());
    return 0;
  }

  /// Sizes the child, places it, and commits the layout to the model — in that
  /// order, once per frame.
  ///
  /// The order is the specification:
  ///
  /// 1. Build the [PanelLayout] for this pass: one `media.baselineFor(size, ...)`,
  ///    then `media.layoutFor(baseline, contentExtent: ...)` with the extent
  ///    from [measureContent] when [measuresContent] and null otherwise. The
  ///    viewport is this box's own [size] — already set by `performResize`,
  ///    because [sizedByParent] — and not `MediaQuery.sizeOf`.
  /// 2. Ask `model.dryApplyLayout(layout)` for the visible extent. **Pure**: it
  ///    commits nothing, which is what makes it safe to ask before the child
  ///    exists at its new size.
  /// 3. Choose the laid extent from [sizing]: [PanelSizing.resize] lays the
  ///    child out at the visible extent; [PanelSizing.translate] and
  ///    [PanelSizing.clip] would lay it out at `model.detents.max` and move it,
  ///    and both throw an [UnimplementedError] naming themselves — the slice
  ///    ships one policy and a wrong guess at the other two is four silent wrong
  ///    frames instead of one loud gap.
  /// 4. `anchor.rectOf(laidExtent, model.edgeOffset, layout)` once. Its size is
  ///    the child's constraints — `BoxConstraints.tight`, both axes, see the
  ///    class doc — and its `topLeft` is the child's [BoxParentData.offset].
  ///    One rect, two uses, so the frame the content is given and the frame the
  ///    user sees are the same object.
  /// 5. `child.layout(tight, parentUsesSize: false)`. `parentUsesSize` is false
  ///    because it is true: this box's size came from its own constraints in
  ///    step 0 and the child's size is already known — it was just dictated.
  ///    Reading `child.size` here would make this box depend on its content and
  ///    cost the downward half of the boundary claim.
  /// 6. Record [panelRect] — the rect from step 4 under [PanelSizing.resize];
  ///    under the other two policies the painted rect and the child's rect
  ///    diverge, which is why the step is named separately from step 4.
  ///    **Before** the commit, because the commit *notifies*, from inside this
  ///    pass, and every listener but this box reads [panelRect] at that moment.
  ///    Published after, they read the previous frame's rect: measured, a
  ///    listener during a commit that describes 812 reads a `panelRect.height`
  ///    of 469.68. Nothing the commit does can change the rect — it is already
  ///    computed, and the child is already laid out at it — so the ordering
  ///    costs nothing and buys a rect that agrees with the extent announced
  ///    beside it.
  /// 7. `model.applyLayout(layout)` **after** the child is laid out. After,
  ///    because the commit may install a new activity and notify, and the child
  ///    must have been laid out against the state the dry pass described rather
  ///    than against the one the commit produced.
  ///
  /// A null child skips steps 4 and 5 and nothing else. A panel with no content
  /// still has a height, still commits its layout and still reports a
  /// [panelRect] — anything less would make the model's state depend on whether
  /// anyone was looking.
  ///
  /// The whole body runs under the re-entrancy guard, in a `try`/`finally`. The
  /// `finally` and not a plain reset, because this body can throw — the two
  /// unshipped [PanelSizing] policies, the four unshipped anchors and both
  /// asserts below all throw from inside it — and a guard left standing after
  /// that would make the panel deaf to its model for the rest of the app's life,
  /// which is a far quieter failure than the one that set it.
  @override
  void performLayout() {
    _inLayout = true;
    try {
      // Read before anything that can run content code, and compared after it.
      // The panel is about to lay the child out against these, and a child that
      // moves them while being laid out is the divergence asserted below.
      final extentOnEntry = _model.extent;
      final activityOnEntry = _model.activity;

      final baseline = _media.baselineFor(
        size,
        anchor: _anchor,
        attachment: _attachment,
      );
      final layout = _media.layoutFor(
        baseline,
        contentExtent: _measuresContent ? measureContent(baseline) : null,
      );

      final visible = _model.dryApplyLayout(layout);
      final laid = switch (_sizing) {
        PanelSizing.resize => visible,
        PanelSizing.translate || PanelSizing.clip => throw UnimplementedError(
          '$_sizing is not in this slice. It would lay the child out at '
          'detents.max and move it, which needs an EdgeOffset this slice pins '
          'at zero; resizing to the extent is the one policy that ships.',
        ),
      };

      // This is the only place in the package where an Extent becomes a
      // BoxConstraints, so it is the only place that can refuse a span nothing
      // can be laid out at. Without it the *framework* refuses instead —
      // "BoxConstraints has a negative minimum height", reported against the
      // content, three layers below whatever produced the extent — which is the
      // same argument computeDryLayout's bounded-axis assert makes for itself.
      // A spring with bounce undershooting a detent near zero is the case that
      // reaches here; SettlingPanelActivity.tick saturates so that it cannot.
      assert(
        laid.px.isFinite && laid.px >= 0,
        'A panel of $laid is not a short panel, it is an absent one — and '
        'absence is EdgeOffset\'s quantity, not Extent\'s, which is "finite and '
        'non-negative by convention" everywhere else in this package. It would '
        'reach PanelAnchor.rectOf and come back as an inverted, empty rect, and '
        'in release the child would be laid out at a negative size.',
      );

      final rect = _anchor.rectOf(laid, _model.edgeOffset, layout);
      final child = this.child;
      if (child != null) {
        child.layout(BoxConstraints.tight(rect.size), parentUsesSize: false);
        (child.parentData! as BoxParentData).offset = rect.topLeft;
      }

      // The dry answer and the committed answer agree by construction — one
      // `resolve`, no bypass — and that argument holds only while nothing
      // mutates the model between the two calls. `child.layout` is between the
      // two calls. Without this the disagreement is silent in both builds: the
      // child is laid out at one height, panelRect records it, and the model
      // reports another, stably, with nothing comparing them.
      assert(
        _model.extent == extentOnEntry &&
            identical(_model.activity, activityOnEntry),
        'The content moved the panel while the panel was laying the content '
        'out. This pass sized the child against an extent of $extentOnEntry and '
        'the model now says ${_model.extent}, so the height about to be '
        'committed is not the height the content was given. A scroll position '
        'writing back from its own layout — applyContentDimensions, '
        'correctPixels — is the shape this takes: whatever needs to move the '
        'panel must do it before the pass, or leave it to the next one.',
      );

      _panelRect = rect;
      _model.applyLayout(layout);
    } finally {
      _inLayout = false;
    }
  }

  /// How long the content wants to be, in the geometry [baseline] describes.
  ///
  /// **Dry layout, never intrinsics, and this is the seam that keeps it that
  /// way.** `child.getDryLayout(bounded)` answers correctly for a `ListView`:
  /// `rendering/viewport.dart:1676` is `sizedByParent => true` and `:1680-1683`
  /// is `computeDryLayout => constraints.biggest` behind a bounded-axis assert.
  /// `getMinIntrinsicHeight` on the same object trips
  /// `debugThrowIfNotCheckingIntrinsics` (`:705-725`) and returns `0.0` when the
  /// assert is suppressed — which is what `stupid_simple_sheet` does, in a method
  /// it named `_illegallyComputeMinIntrinsicHeight`, for the zero it gets back.
  ///
  /// The constraint is loose on the span axis and tight on the cross axis: loose
  /// because the question is how long the content wants to be, tight because the
  /// cross axis is pinned at every detent anyway — [PanelBaseline.crossSpan] —
  /// and a content span measured against a different width is a measurement of
  /// a different layout.
  ///
  /// The span bound is the largest frame any detent could ask for:
  /// `baseline.frameOf(baseline.safeSpan.asDetentValue)`, which is `.full`. It
  /// is derived here rather than passed in so that the rule lives with the
  /// measurement instead of at the call site, where the two could drift. A
  /// content taller than the panel can ever be therefore reports the panel's own
  /// ceiling rather than its true height — the right answer for a detent that
  /// clamps to the baseline, and the only answer a lazy viewport can give.
  ///
  /// A panel with no content measures [Extent.zero]. Nothing is a legitimate
  /// height for nothing, and it is the one case where refusing would be worse:
  /// a content detent in a set with no child is a configuration mistake that
  /// resolves to a zero-height stop, which is visible, rather than an
  /// exception from inside a layout pass.
  ///
  /// `Detent.content` is not in this slice, so nothing calls this unless
  /// [measuresContent] is set. It is specified now because the *shape* is the
  /// part that is hard to change later: a measurement that arrives through
  /// intrinsics cannot be converted into one that arrives through dry layout
  /// without moving the call site.
  ///
  /// Framework memoisation is already correct and this must not add its own.
  /// `RenderBox.getDryLayout` caches per `BoxConstraints`
  /// (`rendering/box.dart:1054`) and `markNeedsLayout` clears that cache
  /// (`:1150`). DESIGN.md §2.5 specifies memoising on
  /// `(constraints, child.debugLayoutCount)`; there is no `debugLayoutCount` in
  /// Flutter 3.44.9, and a second cache keyed on a member that does not exist
  /// would be a stale answer with no invalidation.
  @visibleForTesting
  Extent measureContent(PanelBaseline baseline) {
    final child = this.child;
    if (child == null) return Extent.zero;
    final ceiling = baseline.frameOf(baseline.safeSpan.asDetentValue).px;
    // Written over `baseline.spanAxis` rather than over the anchor, because the
    // baseline is the argument: a caller measuring against a drawer's geometry
    // is asking about its width, and taking the axis from this box's own anchor
    // would answer a question about the other one.
    final measured = child.getDryLayout(switch (baseline.spanAxis) {
      Axis.vertical => BoxConstraints(
        minWidth: baseline.crossSpan,
        maxWidth: baseline.crossSpan,
        maxHeight: ceiling,
      ),
      Axis.horizontal => BoxConstraints(
        maxWidth: ceiling,
        minHeight: baseline.crossSpan,
        maxHeight: baseline.crossSpan,
      ),
    });
    final extent = Extent(switch (baseline.spanAxis) {
      Axis.vertical => measured.height,
      Axis.horizontal => measured.width,
    });
    assert(
      _debugRecordMeasure(extent),
      'The content this panel measures has alternated between two spans across '
      'three consecutive passes: $_recentMeasures. A content extent that '
      'alternates never settles — each pass resolves the content detent to a '
      'height that makes the next pass measure the other one — so the panel '
      'lays out forever at the frame rate, and the one-layout-per-frame budget '
      'this layer is measured by becomes unbounded. Something in the content is '
      'sized by the panel that is measuring it: a Spacer, an Expanded, a '
      'double.infinity, or a child reading the panel height it is deciding.',
    );
    return extent;
  }

  /// Records [measured] and answers whether the last three measurements are an
  /// oscillation — DESIGN.md §2.5's tripwire.
  ///
  /// Called only from inside an `assert`, which is where its side effect belongs:
  /// in release [_recentMeasures] is never allocated and nothing here runs.
  ///
  /// Three is the shortest history that can tell an oscillation from a change.
  /// Two consecutive different answers are content that grew, which is ordinary
  /// and is the whole reason a content detent re-measures at all; `a, b, a` is
  /// content that cannot decide, and there is no fourth frame in which it will.
  bool _debugRecordMeasure(Extent measured) {
    final history = _recentMeasures ??= <Extent>[];
    history.add(measured);
    if (history.length > 3) history.removeAt(0);
    return history.length < 3 ||
        history[0] != history[2] ||
        history[0] == history[1];
  }

  /// The last three [measureContent] answers, oldest first — debug only, and
  /// null until the first measurement.
  List<Extent>? _recentMeasures;

  /// Paints the child at [panelRect]'s corner.
  ///
  /// The offset comes from the child's [BoxParentData], written during layout,
  /// so painting re-derives no geometry. Nothing is clipped: this box is the
  /// size of the viewport and the panel is a rect inside it, and clipping to the
  /// panel is [PanelSizing.clip]'s job rather than every policy's.
  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    context.paintChild(
      child,
      offset + (child.parentData! as BoxParentData).offset,
    );
  }

  /// False — the panel's box is the whole viewport, and only the panel is the
  /// panel.
  ///
  /// This box is laid out at `constraints.biggest` so that it has a coordinate
  /// space to place a rect in, which means it covers everything behind the panel
  /// too. Answering true here would swallow every tap on the background: the
  /// barrier would never see a dismissing tap and a non-modal panel over a map
  /// would make the map dead. The panel is hit-testable exactly where its child
  /// is, which [hitTestChildren] answers.
  @override
  bool hitTestSelf(Offset position) => false;

  /// Hits the child, offset by where it was placed.
  ///
  /// Through `BoxHitTestResult.addWithPaintOffset` so that the offset applied
  /// here and the offset applied in [paint] are the same number read from the
  /// same place. A tap outside the child's rect misses it, and with
  /// [hitTestSelf] false that means the whole box declines and the gesture
  /// reaches whatever is behind the panel.
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: (child.parentData! as BoxParentData).offset,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  /// Translates by the child's placement.
  ///
  /// Needed for `localToGlobal` from inside the panel, which is how a scrollable
  /// in the content works out where it is on the screen — and therefore part of
  /// the scroll handoff, not decoration.
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = (child.parentData! as BoxParentData).offset;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  /// Describes the panel for `debugDumpRenderTree` and for a widget inspector.
  ///
  /// Names the extent, the rect, the sizing policy and the activity, because
  /// "the panel is the wrong height" is answered by which of those four is
  /// surprising, and reading it out of a dump beats adding a print.
  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('extent', _model.extent.px))
      // `missingIfNull`, because the null here means "never laid out" and that
      // is the answer someone dumping the tree most wants: a panel with no rect
      // has not run yet, and every other number below it is from before it did.
      ..add(
        DiagnosticsProperty<Rect>(
          'panelRect',
          _panelRect,
          missingIfNull: true,
          ifNull: 'not laid out yet',
        ),
      )
      ..add(EnumProperty<PanelAnchor>('anchor', _anchor))
      ..add(EnumProperty<EdgeAttachment>('attachment', _attachment))
      ..add(EnumProperty<PanelSizing>('sizing', _sizing))
      ..add(
        FlagProperty(
          'measuresContent',
          value: _measuresContent,
          ifTrue: 'measures content',
        ),
      )
      ..add(DiagnosticsProperty<PanelActivity>('activity', _model.activity))
      ..add(DiagnosticsProperty<PanelMedia>('media', _media));
  }
}
