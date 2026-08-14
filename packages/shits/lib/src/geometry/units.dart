/// The scalar vocabulary every other geometry file is written in.
///
/// Eight extension types over `double`, one per quantity the layer can hold.
/// They cost nothing at runtime — there is no wrapper object and no check — and
/// what they buy is that the confusions listed on each type below stop being
/// wrong numbers and start being compile errors.
///
/// **The honest limit: they erase.** `someExtent == 0.56` compiles and is true,
/// `identical` sees through them, `toString` is the `double`'s, and one handed to
/// a `dynamic` parameter arrives as a plain `double`. None of them declares
/// `implements double`, so `double`'s own operators are *not* inherited and the
/// arithmetic between two different quantities does not compile. That, and
/// argument confusion at a call site, is the whole claim.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A length along the panel's span axis, in logical pixels, measured from the
/// attachment edge to the leading edge — how *big* the panel is.
///
/// This is the animated frame quantity: a resize changes it, and the content
/// lays out inside it. It is not a fraction of anything, and it is not a
/// distance travelled. [Fraction] and [EdgeOffset] are those, and there is no
/// operator on this type that reaches either.
///
/// The bug this separation prevents: an author writes `0.5` meaning "half the
/// container" into an API that resolves it against the *child's* own height, and
/// both quantities are `double` so nothing complains. Here a fraction cannot be
/// passed where a length is wanted.
///
/// Finite and non-negative by convention. Subtraction saturates at [zero]
/// rather than producing a negative span, which nothing downstream could paint.
extension type const Extent(double px) {
  /// No span at all — a panel occupying none of its axis.
  static const Extent zero = Extent(0);

  /// The span covering both, used to add an inset to a bare content height.
  Extent operator +(Extent other) => Extent(px + other.px);

  /// This span less [other], saturating at [zero].
  ///
  /// Saturating keeps a difference of two spans meaningful when the smaller one
  /// is not actually smaller: a single-detent set has `max == min`, and its
  /// travel is zero rather than a negative distance the physics would integrate.
  Extent operator -(Extent other) => Extent(math.max(0.0, px - other.px));

  /// Whether this span is strictly shorter than [other].
  bool operator <(Extent other) => px < other.px;

  /// Whether this span is strictly longer than [other].
  bool operator >(Extent other) => px > other.px;

  /// Orders two spans, for sorting a resolved detent list ascending.
  int compareTo(Extent other) => px.compareTo(other.px);

  /// This span confined to `[lo, hi]`.
  Extent clampTo(Extent lo, Extent hi) => Extent(px.clamp(lo.px, hi.px));

  /// Whether the two spans differ by less than one half of a physical pixel, and
  /// so cannot be told apart on this screen.
  ///
  /// Detent arithmetic is exact but the values that reach it are not — a spring
  /// stops a hair off its target, and iOS itself reports detents already rounded
  /// to the pixel grid. Comparing at the pixel the user can actually see is the
  /// only threshold that means anything, which is why the ratio is required
  /// rather than defaulted.
  bool isCloseTo(Extent other, {required double devicePixelRatio}) =>
      (px - other.px).abs() < 0.5 / devicePixelRatio;
}

/// What a detent resolves to: the span iOS's `resolvedValue(in:)` returns — a
/// **content** span inside the panel's own safe area, not the panel's frame.
///
/// The two differ by the view padding at the attachment edge, and the whole
/// reason this is a separate type from [Extent] is that one `double` for both
/// let the four detent kinds disagree about which one they meant. `.height(200)`
/// added the home indicator's 34pt and answered a frame; `.full` and
/// `.fraction` did not and answered a value. A set holding `.full` and
/// `.height(778)` then had a largest stop of 812 and a largest *permitted* stop
/// of 778 — a panel allowed to rest 34pt above its own ceiling.
///
/// [PanelBaseline.frameOf] is the only way across, and it adds the padding once.
/// Nothing else in the package converts, so the 34pt cannot be added twice or
/// forgotten in one of four places.
extension type const DetentValue(double px) {
  /// A panel showing none of itself.
  static const DetentValue zero = DetentValue(0);

  /// This value confined to `[lo, hi]`, for a ratio that overshoots its
  /// baseline.
  DetentValue clampTo(DetentValue lo, DetentValue hi) =>
      DetentValue(px.clamp(lo.px, hi.px));
}

/// iOS `maxDetentValue`, generalised: the viewport span along the panel's span
/// axis, less the view padding at **both** ends of that axis.
///
/// This is the only quantity a [Fraction] may be resolved against, and that is
/// the point of it being its own type. On an iPhone 17 Pro the baseline is 778
/// while the viewport is 874, so `.fraction(0.5)` is 389 against the baseline
/// and 437 against the viewport — two plausible numbers 48pt apart, from one
/// substitution that no `double`-typed API can refuse.
extension type const Baseline(double px) {
  /// The value of a panel that fills the safe area exactly — iOS `.large`.
  ///
  /// A [DetentValue] and not an [Extent]: filling the safe area is a statement
  /// about content, and the frame that holds it is 34pt taller on a device with
  /// a home indicator. That is measured (G2 gives 778, G6 gives 778 + 34 = 812,
  /// and 874 − 812 is exactly the 62pt top inset iOS leaves above a `.large`
  /// sheet — the three reconcile no other way).
  DetentValue get asDetentValue => DetentValue(px);
}

/// The raw viewport span along the panel's span axis.
///
/// **Not** a detent baseline: it includes the view padding a detent must never
/// see. It exists so the rubber band — which asymptotes at one viewport — has a
/// normaliser that cannot be confused with [Baseline], the two differing by
/// about 96pt on an iPhone 17 Pro.
extension type const ViewportExtent(double px) {}

/// A dimensionless multiplier of a [Baseline].
///
/// Only [Baseline] can be multiplied, so a fraction can never be resolved
/// against a raw viewport or against a child's measured height.
extension type const Fraction(double value) {
  /// This fraction of [baseline], mirrored if negative.
  ///
  /// Mirrored rather than clamped because that is what iOS measurably does: a
  /// `-0.2` fraction resolves at `0.2`, not at zero.
  ///
  /// Answers a [DetentValue], not an [Extent]: a share of the safe area is a
  /// content span, and the frame around it is the attachment padding taller.
  /// Returning an [Extent] here is what made every ratio detent 34pt shorter
  /// than the absolute detent beside it.
  DetentValue of(Baseline baseline) => DetentValue((value * baseline.px).abs());
}

/// Displacement of the panel's attachment edge from the viewport's attachment
/// edge, along the span axis — how far the panel has *come*, not how big it is.
///
/// Zero for an edge-attached panel at rest; positive while entering, leaving,
/// floating or centred. Dismissal moves this and nothing else, so a finger
/// leaving with the panel tracks 1:1 with no conversion factor anywhere.
///
/// The bug the split prevents: multiplying size by presence. A panel that
/// expresses "half dismissed" by halving its [Extent] hands its content a
/// viewport of the wrong height and cannot page, because a page swap that
/// changes the extent then also moves the visible edge. There is deliberately no
/// operator between the two types.
extension type const EdgeOffset(double px) {
  /// No displacement — an edge-attached panel at rest.
  static const EdgeOffset zero = EdgeOffset(0);

  /// The displacement covering both.
  EdgeOffset operator +(EdgeOffset other) => EdgeOffset(px + other.px);

  /// How present the panel is, in `[0, 1]`, for a route animation or a barrier.
  ///
  /// Derived, never driven: it is 1.0 at *every* detent, because a detent
  /// changes [Extent] and leaves this displacement where the placement rests it.
  /// That is what stops a sheet dismissed from a half-height detent starting its
  /// exit animation — and its barrier fade — at 56% instead of 100%.
  ///
  /// [restingOffset] is where this placement sits when it is fully present, and
  /// it is required because zero is not that datum for two of the five anchors.
  /// A centred dialog rests at `(viewportSpan − extent) / 2`: a 300pt dialog in
  /// an 874pt viewport rests at 287, and measuring from zero reports it 4%
  /// present while it is on screen and opaque — a barrier at 4% behind a
  /// finished dialog, and a route simulation seeded from 0.043. An
  /// edge-attached panel passes [EdgeOffset.zero] and reads exactly as it did.
  ///
  /// The denominator is the panel's own span, so a panel is gone once it has
  /// travelled its own length past where it rests. That is right for a
  /// translating entry and is the only span this layer has; a placement whose
  /// entry travels some other distance — a dialog that scales and fades rather
  /// than sliding — owns its own denominator, and that is a `PanelEntry`
  /// concern, not a scalar's.
  double presentationProgress(
    Extent extent, {
    required EdgeOffset restingOffset,
  }) => extent.px == 0
      ? 0.0
      : (1 - (px - restingOffset.px) / extent.px).clamp(0.0, 1.0);
}

/// Velocity along the span axis in px/s, positive when the panel is **growing**,
/// for every placement.
///
/// Produced only by `PanelAnchor`, which is the one file that knows which finger
/// direction grows which panel. Downstream — snapping, the rubber band, the
/// ballistic simulation — never learns that a bottom sheet grows upward.
extension type const ExtentVelocity(double pxPerSecond) {
  /// Not moving.
  static const ExtentVelocity zero = ExtentVelocity(0);

  /// The same speed, in the other direction.
  ExtentVelocity operator -() => ExtentVelocity(-pxPerSecond);

  /// Whether the panel is getting larger.
  bool get isGrowing => pxPerSecond > 0;
}

/// Velocity in px/s in Flutter's scroll space: positive when
/// `ScrollPosition.pixels` **rises**.
///
/// Scroll-positive and panel-positive agree for a top sheet and oppose for a
/// bottom one. Keeping them apart is what stops the sign being negated an even
/// number of times somewhere along the handoff and read as correct.
extension type const ScrollVelocity(double pxPerSecond) {}

/// A position on the fused ballistic axis, spanning
/// `[0, panelTravel + scrollableDistance]`.
///
/// One fling across a panel and the list inside it is one simulation over one
/// coordinate, and this is that coordinate. It is neither an [Extent] nor a
/// scroll offset, and handing it to either is the failure it exists to prevent.
/// Splitting it back into the two is `FusedAxis.split`, which owns the seam.
@internal
extension type const FusedPosition(double px) {}
