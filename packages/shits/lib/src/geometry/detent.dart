import 'package:flutter/painting.dart' show Axis;

import 'baseline.dart';
import 'units.dart';

/// A height a panel is allowed to rest at.
///
/// A detent resolves against a [PanelBaseline] and nothing else, so there is no
/// path from a raw `Size` to a resolved height that skips the safe-area
/// subtraction, and no path from any detent to the keyboard inset.
///
/// Resolution returns a [DetentValue] — a *content* span inside the panel's safe
/// area, which is what iOS's `resolvedValue(in:)` answers. It is not the frame:
/// `PanelBaseline.frameOf` adds the attachment padding, once, for every kind.
/// While each kind decided that for itself, `.height(778)` and `.full` on the
/// same device were 812 and 778, and a set holding both had a largest stop above
/// the largest stop it was told existed.
///
/// Null means *inactive in this context* — iOS's medium detent does exactly this
/// in compact height — and that is a first-class answer, neither an error nor a
/// zero. Callers drop it from the snap set; they never substitute a height.
///
/// `resolve` is also the validation boundary, because an extension type's getter
/// cannot be read inside a const constructor's initializer list
/// (`const_eval_extension_type_method`), so `Detent.height(DetentValue(-100))` cannot
/// refuse itself at the point it is written. Each kind asserts its own payload
/// here instead, naming the value it was handed.
///
/// `resolve` is called about seven times in a single layout pass on iOS, so
/// every implementation must be cheap, pure and allocation-light. Every one here
/// is a multiply and an add.
///
/// This slice ships four kinds. `Detent.content`, `Detent.custom` and
/// `Detent.dismissed` are specified in DESIGN.md and are not built yet.
sealed class Detent {
  /// Allows subclasses to be const.
  const Detent();

  /// The content span this detent asks for on [baseline], or null if it is
  /// inactive there.
  ///
  /// Not a frame. `baseline.frameOf` is what a layout pass wants.
  DetentValue? resolve(PanelBaseline baseline);

  /// The largest height the safe area allows — iOS `.large`.
  ///
  /// Resolves to the baseline exactly: measured at ratio 1.0000 on every device
  /// in the fixture table, which is why nothing here approximates it with a
  /// top-gap constant the way Flutter's own Cupertino sheet does. Its *frame* is
  /// one attachment padding taller — 812 where the value is 778 — which is where
  /// the 62pt gap iOS leaves above a `.large` sheet comes from.
  static const Detent full = FullDetent._();

  /// iOS `.medium`.
  ///
  /// 0.56 of the baseline, measured identical across four devices and two
  /// safe-area geometries. Not 0.5 — see [MediumDetent.ratio], which explains
  /// what simplifying it costs.
  static const Detent medium = MediumDetent._();

  /// A multiple of the baseline. Negative fractions mirror rather than clamp.
  const factory Detent.fraction(Fraction fraction) = FractionDetent._;

  /// An absolute height, measured inside the panel's own safe area.
  ///
  /// [edgeAttached] overrides the placement for this detent alone: null follows
  /// the placement, false refuses the attachment padding the placement would
  /// have added. It exists because whether a *floating* partial sheet on iOS
  /// still absorbs the home indicator is measured contradictorily, and this is
  /// where the answer lands when a device settles it.
  const factory Detent.height(DetentValue height, {bool? edgeAttached}) =
      AbsoluteDetent._;
}

/// The detent [Detent.full] names.
final class FullDetent extends Detent {
  const FullDetent._();

  @override
  DetentValue? resolve(PanelBaseline baseline) =>
      baseline.safeSpan.asDetentValue;

  @override
  bool operator ==(Object other) => other is FullDetent;

  @override
  int get hashCode => (FullDetent).hashCode;

  @override
  String toString() => 'Detent.full';
}

/// The detent [Detent.medium] names.
final class MediumDetent extends Detent {
  const MediumDetent._();

  /// The measured constant: 0.56 of the baseline.
  ///
  /// Constant across four devices and two safe-area geometries. On an iPhone 17
  /// Pro it gives 435.68pt, which the platform reports as 435.667 after
  /// rounding to the 3x pixel grid — the same number, not a different one.
  ///
  /// 0.5 gives 389.0. Anyone tidying 0.56 into a half will be 46pt short on
  /// every device, which is why `detent_test.dart` asserts both numbers in one
  /// test.
  static const Fraction ratio = Fraction(0.56);

  /// The value, or null in compact height where iOS deactivates this detent.
  ///
  /// Asserts a vertical span axis: 0.56 is a measurement of an iPhone's height
  /// and 0.56 of a drawer's width is a measurement of nothing. A horizontal
  /// panel that wants a middle stop says `Detent.fraction`, and owns the number.
  @override
  DetentValue? resolve(PanelBaseline baseline) {
    assert(
      baseline.spanAxis == Axis.vertical,
      'Detent.medium is 0.56 of an iPhone height, measured. It has no meaning '
      'on a horizontal panel — use Detent.fraction and choose the number.',
    );
    if (baseline.isCompactHeight) return null;
    return ratio.of(baseline.safeSpan);
  }

  @override
  bool operator ==(Object other) => other is MediumDetent;

  @override
  int get hashCode => (MediumDetent).hashCode;

  @override
  String toString() => 'Detent.medium';
}

/// The detent [Detent.fraction] names.
final class FractionDetent extends Detent {
  const FractionDetent._(this.fraction);

  /// The multiplier applied to the baseline.
  final Fraction fraction;

  /// The value, clamped to the baseline and mirrored if [fraction] is negative.
  ///
  /// Both behaviours are measured, and they are not the same behaviour: a
  /// fraction above 1 is capped at the baseline, while a fraction below 0 comes
  /// back as its absolute value rather than as zero.
  ///
  /// A non-finite fraction is refused here rather than clamped, because
  /// `num.clamp` orders NaN *above* its upper limit: `Fraction(nan)` resolved to
  /// the whole baseline and was indistinguishable from `Detent.full`, so a
  /// division that produced a NaN somewhere upstream arrived as a plausible
  /// sheet instead of as a failure. Infinity does the same.
  @override
  DetentValue? resolve(PanelBaseline baseline) {
    assert(
      fraction.value.isFinite,
      'Detent.fraction(${fraction.value}) has no height. num.clamp orders NaN '
      'and infinity above the upper limit, so this would resolve to the whole '
      'baseline and read as Detent.full.',
    );
    return fraction
        .of(baseline.safeSpan)
        .clampTo(DetentValue.zero, baseline.safeSpan.asDetentValue);
  }

  @override
  bool operator ==(Object other) =>
      other is FractionDetent && other.fraction == fraction;

  @override
  int get hashCode => Object.hash(FractionDetent, fraction);

  @override
  String toString() => 'Detent.fraction(${fraction.value})';
}

/// The detent [Detent.height] names.
final class AbsoluteDetent extends Detent {
  const AbsoluteDetent._(this.height, {this.edgeAttached});

  /// The height asked for, inside the panel's safe area.
  ///
  /// A [DetentValue] and not an [Extent], because those are the two things this
  /// whole vocabulary exists to keep apart and this constructor is the one place
  /// a frame could be handed back in as if it were a content span. It could:
  /// `DetentSet([Detent.full]).resolve(b).max` is a *frame* of 812, and feeding
  /// that to `Detent.height` used to resolve to 812 and frame at 846 — 34pt
  /// gained, with no error anywhere.
  ///
  /// The one exception is documented on [resolve]: a detent that refuses the
  /// attachment padding is naming a frame, and pays for it there.
  final DetentValue height;

  /// Whether to add the placement's attachment padding: null follows the
  /// placement, false refuses it.
  ///
  /// True and null behave identically today, because a floating placement
  /// resolves its baseline with [PanelBaseline.attachedPadding] already zeroed —
  /// there is nothing left for an override to opt back into. If a measurement
  /// ever shows a floating sheet absorbing the home indicator, the fix is a
  /// second field on the baseline, not a change here.
  final bool? edgeAttached;

  /// [height] as written — it is already a content span, which is what a detent
  /// value is — unless this detent refuses the padding its placement would add.
  ///
  /// A detent that refuses it is naming a *frame*, and `frameOf` adds the
  /// padding to everything, so the value it must carry is that frame less the
  /// padding: the content that is actually clear of the attachment edge. A 10pt
  /// frame against a 34pt home indicator carries −24, and that is not a bug to
  /// clamp away — it is a frame with nothing above the indicator, which is what
  /// was asked for. `frameOf` saturates at zero, so the rect stays valid.
  ///
  /// There is no floor and no ceiling. A 10pt detent is 44pt of frame around
  /// 10pt of content on an edge-attached placement and 10pt on a floating one —
  /// iOS imposes no minimum and neither does this.
  ///
  /// A negative or non-finite height is refused. `Extent(-100)` resolved to −66
  /// and reached `PanelAnchor.rectOf` as `Rect.fromLTRB(0, 940, 402, 874)` — an
  /// inverted rect, bottom above top, which paints nothing and reports a
  /// negative height to everything that measures it.
  @override
  DetentValue? resolve(PanelBaseline baseline) {
    assert(
      height.px.isFinite && height.px >= 0,
      'Detent.height(${height.px}) is not a height. A negative one resolves to '
      'a negative span and reaches PanelAnchor.rectOf as an inverted rect.',
    );
    return DetentValue(
      (edgeAttached ?? true)
          ? height.px
          : height.px - baseline.attachedPadding.px,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AbsoluteDetent &&
      other.height == height &&
      other.edgeAttached == edgeAttached;

  @override
  int get hashCode => Object.hash(AbsoluteDetent, height, edgeAttached);

  @override
  String toString() =>
      'Detent.height(${height.px}'
      '${edgeAttached == null ? '' : ', edgeAttached: $edgeAttached'})';
}
