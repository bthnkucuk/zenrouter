import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import 'anchor.dart';
import 'units.dart';

/// The viewport height at or below which `Detent.medium` is inactive.
///
/// iOS gates its medium detent on a *compact height* size class, which
/// `MediaQuery` does not expose. Every iPhone in landscape is compact — 320pt on
/// an SE through 440pt on a 17 Pro Max — and every iPhone in portrait is not,
/// starting at 568pt, so any threshold inside `(440, 568]` reproduces the
/// platform on every device Apple ships. 480 is the round number in that window.
///
/// This is the one number in the geometry layer that is ours rather than
/// measured, and it is a threshold, not a fact about a device.
const double kCompactHeightThreshold = 480.0;

/// Everything a detent is allowed to resolve against.
///
/// Constructed from the viewport size and `viewPadding` alone. There is
/// deliberately no `viewInsets` field and no `padding` field, so the rule that
/// costs the most to forget — that a detent must not shrink when the keyboard
/// opens — is a fact about this type rather than something to remember.
/// `MediaQueryData.padding` collapses toward zero with the keyboard up while
/// `viewPadding.bottom` keeps its 34pt, so a design that could reach either
/// would make every detent 34pt shorter the moment a field was focused. Here a
/// detent physically cannot see them: `Detent.resolve` takes this and nothing
/// else.
@immutable
final class PanelBaseline {
  /// Creates a baseline from already-resolved spans.
  ///
  /// Prefer [PanelBaseline.from], which derives all six from a viewport and its
  /// view padding. This exists for tests and for a host that has already done
  /// the arithmetic.
  const PanelBaseline({
    required this.safeSpan,
    required this.viewportSpan,
    required this.attachedPadding,
    required this.crossSpan,
    required this.isCompactHeight,
    required this.spanAxis,
  });

  /// Derives the baseline for [anchor] in a viewport of [viewport].
  ///
  /// [viewPadding] must come from `MediaQuery.viewPaddingOf`. It is the only
  /// inset this type accepts, and the reason is in the class doc.
  factory PanelBaseline.from({
    required Size viewport,
    required EdgeInsets viewPadding,
    required PanelAnchor anchor,
    required TextDirection textDirection,
    EdgeAttachment attachment = EdgeAttachment.edgeAttached,
  }) {
    final spanAxis = anchor.spanAxis;
    return PanelBaseline(
      safeSpan: anchor.baselineOf(viewport, viewPadding),
      viewportSpan: ViewportExtent(switch (spanAxis) {
        Axis.vertical => viewport.height,
        Axis.horizontal => viewport.width,
      }),
      attachedPadding: switch (attachment) {
        EdgeAttachment.edgeAttached => anchor.attachedPadding(
          viewPadding,
          textDirection,
        ),
        EdgeAttachment.floating => Extent.zero,
      },
      crossSpan: switch (spanAxis) {
        Axis.vertical => viewport.width,
        Axis.horizontal => viewport.height,
      },
      isCompactHeight: viewport.height <= kCompactHeightThreshold,
      spanAxis: spanAxis,
    );
  }

  /// The span every fractional detent is resolved against — iOS
  /// `maxDetentValue`, 778 on an iPhone 17 Pro.
  final Baseline safeSpan;

  /// The raw viewport span, 874 on the same device.
  ///
  /// The rubber band's normaliser and nothing else: it includes the padding a
  /// detent must not see, and the 96pt between the two is exactly the mistake
  /// [Baseline] and [ViewportExtent] exist to keep apart.
  final ViewportExtent viewportSpan;

  /// The view padding at the attachment edge, which an absolute detent adds.
  ///
  /// [Extent.zero] when the panel floats or is centred, so a detent that follows
  /// the placement needs no branch: it adds this unconditionally.
  final Extent attachedPadding;

  /// The viewport span across the panel — pinned at every detent, because only
  /// the leading edge moves.
  ///
  /// Raw, with no safe area subtracted: insetting the cross axis is a
  /// `CrossAxisFit` policy applied to the rect, not a change to what a detent
  /// resolves to.
  final double crossSpan;

  /// Whether the height size class is compact, which makes `Detent.medium`
  /// inactive.
  final bool isCompactHeight;

  /// The axis the panel resizes along.
  final Axis spanAxis;

  /// The frame span that holds [value] — the **only** conversion from what a
  /// detent resolves to into what a panel is laid out at.
  ///
  /// It adds [attachedPadding], which is G6 verbatim from the SDK header: a
  /// `.height(200)` detent gives a sheet whose height is `200 + safeAreaInsets`
  /// at the attachment edge, so the number the author wrote is the content and
  /// the frame is taller. Applied to `.full` on an iPhone 17 Pro that is
  /// 778 + 34 = 812, leaving the frame's top edge at 874 − 812 = 62 — exactly
  /// the top inset, which is G3. G2, G3 and G6 hold together only through this
  /// one function, and they held apart before it existed.
  ///
  /// Being the only crossing is the point. Four detent kinds each deciding
  /// whether to add the padding is how `.full` came to resolve 34pt shorter than
  /// a `.height` detent asking for the same span, inside one set.
  ///
  /// Saturates at zero. A detent that refuses the padding can legitimately carry
  /// a negative value — a 10pt frame at the bottom edge is 10pt of frame with
  /// −24pt of content clear of the home indicator — but a *frame* below zero
  /// would reach `PanelAnchor.rectOf` and come back as an inverted, empty rect
  /// that paints nothing and reports a negative height.
  Extent frameOf(DetentValue value) =>
      Extent(math.max(0.0, value.px + attachedPadding.px));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PanelBaseline &&
          other.safeSpan == safeSpan &&
          other.viewportSpan == viewportSpan &&
          other.attachedPadding == attachedPadding &&
          other.crossSpan == crossSpan &&
          other.isCompactHeight == isCompactHeight &&
          other.spanAxis == spanAxis;

  @override
  int get hashCode => Object.hash(
    safeSpan,
    viewportSpan,
    attachedPadding,
    crossSpan,
    isCompactHeight,
    spanAxis,
  );

  @override
  String toString() =>
      'PanelBaseline(safeSpan: ${safeSpan.px}, viewportSpan: '
      '${viewportSpan.px}, attachedPadding: ${attachedPadding.px}, crossSpan: '
      '$crossSpan, isCompactHeight: $isCompactHeight, spanAxis: ${spanAxis.name})';
}
