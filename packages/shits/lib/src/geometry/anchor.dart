import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'layout.dart';
import 'units.dart';

/// Where a panel is attached, and therefore which way it grows.
///
/// This is the only place in the package that knows a screen direction, a
/// [TextDirection], or a velocity sign. Everything downstream — the rubber band,
/// the projection, the snapping, the simulations — is placement-blind, which is
/// what makes "five placements, one model" a fact rather than an aspiration. If
/// a physics file ever mentions [bottom], the separation has been lost.
///
/// [leading] and [trailing] resolve against the ambient [TextDirection], so a
/// drawer mirrors in RTL without the app asking. That is why this is an anchor
/// enum and not an `AxisDirection` field.
enum PanelAnchor {
  /// Attached to the bottom of the viewport, growing upward. A sheet.
  bottom,

  /// Attached to the top of the viewport, growing downward.
  top,

  /// Attached to the reading-start edge, growing across. A drawer.
  leading,

  /// Attached to the reading-end edge, growing across. A rail.
  trailing,

  /// Attached to nothing, growing symmetrically about the centre. A dialog.
  center;

  /// The axis the panel resizes along.
  ///
  /// [center] is vertical: a centred panel still has one axis it resizes on, and
  /// a dialog that grows with its content grows downward on both edges. A
  /// centred placement that wants the other axis carries its own, because that
  /// choice belongs to the placement rather than to the anchor.
  Axis get spanAxis => switch (this) {
    bottom || top || center => Axis.vertical,
    leading || trailing => Axis.horizontal,
  };

  /// Whether this anchor is defined by the reading direction rather than by the
  /// screen, and so mirrors in RTL.
  bool get isDirectional => this == leading || this == trailing;

  /// The direction the leading edge travels as the panel grows.
  ///
  /// For [center] both edges travel and this names the one that moves away from
  /// the attachment side by convention — up, for the same reason a dragged
  /// dialog grows when the finger rises. [rectOf] is what actually encodes the
  /// symmetry; nothing should read this expecting a single moving edge there.
  AxisDirection resolve(TextDirection textDirection) => switch (this) {
    bottom || center => AxisDirection.up,
    top => AxisDirection.down,
    leading =>
      textDirection == TextDirection.ltr
          ? AxisDirection.right
          : AxisDirection.left,
    trailing =>
      textDirection == TextDirection.ltr
          ? AxisDirection.left
          : AxisDirection.right,
  };

  /// iOS `maxDetentValue` for this anchor: the viewport span on [spanAxis], less
  /// the view padding at **both** ends of that axis.
  ///
  /// Both ends, not the attached one: a full-height sheet stops below the notch
  /// *and* clears the home indicator, and 874 − 62 − 34 = 778 is the measured
  /// number on an iPhone 17 Pro. Specialising the same sentence to a horizontal
  /// anchor gives a drawer whose full state stops at a landscape notch.
  ///
  /// Pass `MediaQuery.viewPaddingOf`, never `paddingOf`: padding collapses toward
  /// zero when the keyboard is up, which would silently shorten every detent the
  /// moment a field is focused.
  Baseline baselineOf(Size viewport, EdgeInsets viewPadding) =>
      switch (spanAxis) {
        Axis.vertical => Baseline(
          math.max(0.0, viewport.height - viewPadding.top - viewPadding.bottom),
        ),
        Axis.horizontal => Baseline(
          math.max(0.0, viewport.width - viewPadding.left - viewPadding.right),
        ),
      };

  /// The view padding at the attachment edge, which an absolute detent adds so
  /// its height is measured inside the panel's own safe area.
  ///
  /// `Detent.height(200)` on a device with a 34pt home indicator is a 234pt
  /// frame with 200pt of usable content. A drawer absorbs a landscape notch by
  /// the same rule rather than by an analogy to it.
  ///
  /// [center] has no attachment edge and always answers [Extent.zero]; a centred
  /// panel is floating by construction.
  Extent attachedPadding(
    EdgeInsets viewPadding,
    TextDirection textDirection,
  ) => switch (this) {
    bottom => Extent(viewPadding.bottom),
    top => Extent(viewPadding.top),
    leading => Extent(
      textDirection == TextDirection.ltr ? viewPadding.left : viewPadding.right,
    ),
    trailing => Extent(
      textDirection == TextDirection.ltr ? viewPadding.right : viewPadding.left,
    ),
    center => Extent.zero,
  };

  /// The panel-space velocity a pointer moving at [pixelsPerSecond] implies.
  ///
  /// Takes the raw `Velocity.pixelsPerSecond` rather than a `Velocity`, because
  /// that type lives in the gestures library and this layer deliberately imports
  /// no binding.
  ExtentVelocity fromPointer(
    Offset pixelsPerSecond,
    TextDirection textDirection,
  ) {
    final component = switch (spanAxis) {
      Axis.vertical => pixelsPerSecond.dy,
      Axis.horizontal => pixelsPerSecond.dx,
    };
    return ExtentVelocity(component * _pointerSign(textDirection));
  }

  /// The panel-space velocity a scroll position moving at [velocity] implies.
  ExtentVelocity fromScroll(
    ScrollVelocity velocity,
    TextDirection textDirection,
  ) => ExtentVelocity(velocity.pxPerSecond * _scrollSign(textDirection));

  /// The scroll-space velocity that would move a list the way [velocity] moves
  /// this panel — the inverse of [fromScroll], used to hand a fling on across
  /// the seam.
  ScrollVelocity toScroll(
    ExtentVelocity velocity,
    TextDirection textDirection,
  ) => ScrollVelocity(velocity.pxPerSecond * _scrollSign(textDirection));

  /// The change in [Extent] that a change of [delta] in scroll-pixel space
  /// implies.
  ///
  /// [delta] is measured the way [ScrollVelocity] is — positive when
  /// `ScrollPosition.pixels` rises — which is the **negation** of the drag delta
  /// `ScrollPosition.applyUserOffset` receives. A caller holding a raw drag
  /// delta negates it before arriving here.
  double extentDeltaFromScrollDelta(
    double delta,
    TextDirection textDirection,
  ) => delta * _scrollSign(textDirection);

  /// The rectangle the panel occupies in the viewport, given how big it is and
  /// how far its attachment edge has been displaced.
  ///
  /// Only the leading edge moves; the other three are pinned. That one sentence
  /// is every placement's cross-axis behaviour, which is why no widget in this
  /// package computes a rect of its own.
  ///
  /// [extent] is a **frame** span — `PanelBaseline.frameOf` of what a detent
  /// resolved to, never the detent value itself. `.full` on an iPhone 17 Pro is
  /// a value of 778 and a frame of 812, and this returns a top edge of 62.
  ///
  /// Throws [UnimplementedError] for every anchor but [bottom]. This slice ships
  /// the bottom sheet, and the other four need `CrossAxisFit` — which decides
  /// whether the cross axis fills, insets or centres — as a fifth parameter.
  /// Guessing them now would be four silent wrong rects instead of one loud gap.
  Rect rectOf(Extent extent, EdgeOffset edgeOffset, PanelLayout layout) {
    if (this != bottom) {
      throw UnimplementedError(
        'PanelAnchor.$name has no rect yet: this slice implements the bottom '
        'anchor only. Adding one means adding the CrossAxisFit parameter with '
        'it, so the cross axis is a policy rather than a fill assumption.',
      );
    }
    // A baseline knows which axis it measured, and reading a horizontal one
    // through a vertical anchor silently swaps the whole rect: a drawer's
    // baseline on a 17 Pro carries viewportSpan 402 and crossSpan 874, so a
    // bottom sheet asked for its rect against it comes back 874 wide on a
    // 402-wide device, with a top edge of −376. Nothing downstream can tell that
    // from a real rect — it is finite, non-empty and plausibly shaped.
    assert(
      spanAxis == layout.baseline.spanAxis,
      'PanelAnchor.$name spans ${spanAxis.name} and this layout was measured '
      'for a ${layout.baseline.spanAxis.name} panel. The rect would take its '
      'span from the cross axis and its width from the span axis.',
    );
    final viewportSpan = layout.baseline.viewportSpan.px;
    final attachmentEdge = viewportSpan - edgeOffset.px;
    return Rect.fromLTRB(
      0,
      attachmentEdge - extent.px,
      layout.baseline.crossSpan,
      attachmentEdge,
    );
  }

  /// +1 where a pointer moving along the axis' positive direction grows the
  /// panel, −1 where it shrinks it.
  double _pointerSign(TextDirection textDirection) => switch (this) {
    // A sheet and a dialog both grow when the finger rises, and `dy` falls as it
    // does.
    bottom || center => -1.0,
    top => 1.0,
    leading => textDirection == TextDirection.ltr ? 1.0 : -1.0,
    trailing => textDirection == TextDirection.ltr ? -1.0 : 1.0,
  };

  /// +1 where a rising `ScrollPosition.pixels` grows the panel, −1 where it
  /// shrinks it.
  ///
  /// [textDirection] does not move this sign, and that is a result rather than
  /// an oversight: a horizontal scrollable's axis mirrors in RTL at the same
  /// time as a [leading] or [trailing] anchor does, so the two flips cancel. The
  /// parameter stays because a caller cannot know that without reading this, and
  /// because the claim is asserted in `anchor_test.dart` rather than trusted.
  double _scrollSign(TextDirection textDirection) => switch (this) {
    bottom || center => 1.0,
    top => -1.0,
    leading => -1.0,
    trailing => 1.0,
  };
}

/// Whether a panel sits against its attachment edge or floats clear of it.
///
/// This decides whether an absolute detent absorbs the view padding at that edge
/// — a 200pt sheet is a 234pt frame when it reaches the bottom of the screen and
/// a 200pt frame when it hovers above it.
///
/// DESIGN.md files this with `Placement`, in `geometry/placement.dart`, which
/// this slice does not build. It lives here because it is the switch that gates
/// [PanelAnchor.attachedPadding], and it moves when `Placement` lands.
enum EdgeAttachment {
  /// Against the edge; the view padding there is inside the panel.
  edgeAttached,

  /// Clear of the edge; the panel's frame is all content.
  floating,
}
