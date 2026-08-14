import 'package:meta/meta.dart';

import '../geometry/units.dart';

/// chpwn's rubber band: what a panel does when it is dragged past a stop it is
/// not allowed to pass.
///
/// One function and its analytic derivative, over the raw distance the finger
/// has travelled beyond the stop:
///
/// ```text
///   u(x)     = 1 + c·x/L
///   map(x)   = c·x / u(x)     the displacement to apply;  asymptote L
///   slope(x) = c / u(x)²      the drag-end velocity scale; slope(0) = c
/// ```
///
/// [map] is what a drag applies. [slope] is what the drag *end* multiplies the
/// release velocity by, and it is `d(map)/dx` — not a second resistance formula
/// that resembles the first. `rubber_band_test.dart` asserts that against a
/// numeric derivative of [map] to 1e-6, and that test is the reason this is a
/// class rather than two expressions at two call sites.
///
/// The bug it makes inexpressible: `stupid_simple_sheet-1.0.0-dev.2` scales the
/// delta by `1/(1 + overshoot·R)` while dragging
/// (`lib/stupid_simple_sheet.dart:557`) and the release velocity by
/// `1/(maxExtent + overshoot·R)` (`:600`), under the comment *"Scale the
/// velocity by the same resistance factor that was applied during dragging"*.
/// The second is the first divided by a height — different by a factor of
/// several hundred, and dimensionally not even the same kind of quantity.
/// Nothing could have caught it, because nothing but the comment claimed the two
/// were related.
///
/// **Normalised to the viewport, never to the panel.** The resistance a finger
/// feels at 100pt of overdrag has to be the same whether the panel is at its
/// smallest detent or its largest, and it has to be the same on a drawer as on a
/// sheet. Normalising to the current extent — or to the detent baseline, which
/// is 96pt shy of the viewport on an iPhone 17 Pro — makes the feel drift with
/// the geometry. [ViewportExtent] is a separate type from [Baseline] precisely
/// so that this cannot be wired to the wrong one.
///
/// **The curve is bounded and Flutter's is not.** `map` asymptotes at exactly
/// one viewport, so there is a hardest pull past which the panel simply stops
/// moving. `BouncingScrollPhysics` uses `0.52·(1 − overscroll/viewport)²`, which
/// is a different curve with a different constant at zero and, since it clamps
/// the fraction rather than the displacement, no asymptote at all.
@immutable
final class RubberBand {
  /// A band that asymptotes at [viewport], with marginal resistance [c] at zero
  /// overshoot.
  ///
  /// **Not const, though DESIGN.md §2.6 writes it so.** Dart forbids
  /// extension-type member access inside a constant expression
  /// (`const_eval_extension_type_method`), so a const constructor could not read
  /// `viewport.px` to assert on it. The assert is the half worth keeping: it is
  /// the fixed form of `smooth_sheets`' `BouncingSheetPhysics` dividing by a
  /// `bounceExtent` nothing stopped from being zero. And a viewport is a
  /// measurement taken during layout, so a `const RubberBand` could not be
  /// written at a real call site regardless.
  RubberBand({required this.viewport, this.c = 0.55})
    : assert(
        viewport.px > 0,
        'A rubber band normalised to a zero viewport divides by zero and hands '
        'the panel a NaN extent. A panel that exists is inside a viewport that '
        'has a span.',
      ),
      assert(
        c > 0 && c <= 1,
        'Resistance is the fraction of the first pixel of overdrag that shows '
        'up on screen. At 0 the panel is welded shut; above 1 it moves further '
        'than the finger.',
      );

  /// The span the band is normalised to, and the displacement it asymptotes at.
  ///
  /// `PanelBaseline.viewportSpan`, not `safeSpan`: the reference is the screen
  /// the panel is dragged across, not the region its detents are measured in.
  final ViewportExtent viewport;

  /// Marginal resistance at zero overshoot — the slope of [map] at the origin.
  ///
  /// 0.55 is chpwn's measurement of UIScrollView, and it is the number the first
  /// pixel past a detent moves by. Flutter's `BouncingScrollPhysics` uses 0.52
  /// at the same point; the two curves diverge sharply after that, so matching
  /// one does not approximate the other.
  ///
  /// Named `c` because DESIGN.md §2.6 names it `c` and every published statement
  /// of this formula names it `c`.
  final double c;

  /// The furthest the panel can be dragged past its stop, however hard it is
  /// pulled.
  ///
  /// Approached and not arrived at, which is what makes the overdrag
  /// self-limiting instead of merely slow — **in exact arithmetic, and in this
  /// one up to about `2^53·L/c` px of raw overshoot**, which is 1.43e19 on an
  /// 874pt viewport. Past there `c·x/L` exceeds 2^53, the `1 +` in [_u] no
  /// longer changes it, and the ratio collapses to exactly one: `map(1e20)` is
  /// exactly 874.0, and a little further out rounding puts it one ulp *above*.
  ///
  /// The bound is stated rather than defended against because a drag of 1.4e19
  /// px is not a gesture, and because the alternative — clamping every [map] to
  /// one ulp below the asymptote — buys a truer doc comment with a lie in the
  /// hot path. What matters is that [inverse]'s domain stops where this
  /// saturation starts, and it says so.
  Extent get asymptote => Extent(viewport.px);

  /// The displacement to apply for [rawOvershoot] of un-resisted travel past the
  /// stop.
  ///
  /// [rawOvershoot] is the **accumulated** raw distance, not this frame's delta.
  /// That is what makes the band path-independent: a hundred one-pixel deltas
  /// and one hundred-pixel delta land in the same place. Feeding it per-frame
  /// deltas and summing the results does not — `smooth_sheets` integrates
  /// `kTouchSlop`-clamped fragments (`lib/src/physics.dart:213-236`) and so the
  /// same gesture ends somewhere different depending on the frame rate.
  ///
  /// A magnitude, so it is never negative: the band is used at both ends of the
  /// travel, and the end that shrinks passes the magnitude and subtracts. A
  /// signed result would have to be a negative [Extent], and [Extent] is
  /// non-negative for every consumer downstream of here.
  Extent map(double rawOvershoot) {
    assert(
      rawOvershoot >= 0 && rawOvershoot.isFinite,
      'The band takes a magnitude. Drag past the bottom of the travel is the '
      'same curve applied to the same distance and subtracted, not a negative '
      'overshoot.',
    );
    return Extent(c * rawOvershoot / _u(rawOvershoot));
  }

  /// What to multiply the release velocity by, at [rawOvershoot] of accumulated
  /// raw travel past the stop.
  ///
  /// The derivative of [map], so the pixel the finger is releasing at is moving
  /// at exactly the speed the panel continues with — the settle picks up the
  /// motion instead of restarting it.
  ///
  /// Strictly positive up to about `sqrt(maxFinite)·L/c` px of overshoot —
  /// 2.13e157 on an 874pt viewport — and that much is load-bearing: a scaled
  /// velocity is still a velocity, and no amount of overdrag a gesture can
  /// produce turns a release into a standing start. Past that bound `u²`
  /// overflows to infinity and this returns 0.0.
  ///
  /// The claim is bounded rather than held because it cannot be held. Writing
  /// the same quantity as `(c/u)/u` avoids the overflow and pushes the first
  /// zero out to ~7e164, where the quotient underflows instead; there is no
  /// association of `c/u²` that stays positive for every finite `double`. A
  /// stated bound with a test on both sides of it is worth more than a claim
  /// that is false somewhere unnamed.
  double slope(double rawOvershoot) {
    assert(
      rawOvershoot >= 0 && rawOvershoot.isFinite,
      'The band takes a magnitude — see map().',
    );
    final u = _u(rawOvershoot);
    return c / (u * u);
  }

  /// The raw overshoot that produced an [applied] displacement — [map] run
  /// backwards.
  ///
  /// A panel that comes back from an overdrag has to put the accumulated raw
  /// position back where the finger actually is, or the next delta resumes from
  /// a resisted position and the resistance compounds. This is the only way to
  /// recover it without the drag keeping a second, shadow copy of the position
  /// that can desync from the first.
  ///
  /// The domain is `[0, asymptote)`, which is [map]'s range everywhere it is
  /// invertible. The two meet exactly at the saturation described on
  /// [asymptote]: from about 1.43e19 px of raw overshoot [map] answers the
  /// asymptote itself, every raw position above that answers the same, and there
  /// is nothing left to recover — so this refuses rather than returning one of
  /// them. Nothing a gesture can produce gets near it.
  double inverse(Extent applied) {
    final limit = viewport.px;
    assert(
      applied.px >= 0 && applied.px < limit,
      'Displacements at or beyond one viewport are outside the band: map() is '
      'strictly below $limit for every overshoot below the saturation bound on '
      'asymptote, and at or above it every raw position gives the same answer, '
      'so no raw position can be recovered from one.',
    );
    return limit * applied.px / (c * (limit - applied.px));
  }

  /// `1 + c·x/L` — the one intermediate both [map] and [slope] are written in
  /// terms of, so that the derivative relationship is visible in the source and
  /// not only in the test.
  ///
  /// Written as `c·x/u` rather than as DESIGN.md's algebraically equal
  /// `(1 − 1/u)·L`, which subtracts two nearly equal numbers for small
  /// overshoot. The cancellation is real but it is **not** worth a behavioural
  /// claim: measured across the first 20 logical pixels the two forms disagree
  /// by at most ~4e-13 px, far below anything a display or a test can see, and
  /// substituting one for the other leaves this file's whole suite green.
  ///
  /// So this is a preference for the form that cannot cancel, not a fix for a
  /// defect — said plainly because an unfalsifiable justification in a comment
  /// is worse than none: the next reader takes it for a measured constraint and
  /// preserves it for a reason that was never there.
  double _u(double rawOvershoot) => 1 + c * rawOvershoot / viewport.px;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RubberBand && other.viewport == viewport && other.c == c;

  @override
  int get hashCode => Object.hash(viewport, c);

  @override
  String toString() => 'RubberBand(viewport: ${viewport.px}, c: $c)';
}
