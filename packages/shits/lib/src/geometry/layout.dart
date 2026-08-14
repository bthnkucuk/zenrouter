import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import 'baseline.dart';
import 'units.dart';

/// Everything one layout pass knows about the space the panel sits in.
///
/// A value type with full equality, so a model can decide whether a pass changed
/// anything with a single `==` rather than by comparing five fields by hand and
/// leaving a note to make the class immutable one day.
///
/// Note what is separated here: [baseline] is what detents resolve against and
/// cannot see the keyboard, while [viewInsets] is right here in the same object.
/// That is deliberate — the keyboard policy is a real thing that needs the real
/// inset, and it is the only thing that reads it. Nothing hands [viewInsets] to
/// a detent, because `Detent.resolve` takes a [PanelBaseline].
@immutable
final class PanelLayout {
  /// Creates the layout for one pass.
  const PanelLayout({
    required this.baseline,
    required this.viewInsets,
    required this.contentExtent,
    required this.devicePixelRatio,
    required this.textDirection,
  }) : assert(
         devicePixelRatio > 0,
         'A zero device pixel ratio makes every pixel-level comparison in the '
         'layer silently false.',
       );

  /// What detents resolve against.
  final PanelBaseline baseline;

  /// The keyboard and anything else that obscures without changing the safe
  /// area.
  ///
  /// Read by the keyboard policy alone. A detent has no way to reach it.
  final EdgeInsets viewInsets;

  /// How tall the content measured this pass, or null if it was not measured.
  ///
  /// Null is the ordinary case: only a content-sized detent asks for a measure,
  /// and this slice does not ship one. It is required rather than defaulted so
  /// that a render pass has to say which case it is in.
  final Extent? contentExtent;

  /// Physical pixels per logical pixel, for comparisons at the resolution the
  /// user can actually see.
  final double devicePixelRatio;

  /// The ambient reading direction, which decides which edge is leading.
  final TextDirection textDirection;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PanelLayout &&
          other.baseline == baseline &&
          other.viewInsets == viewInsets &&
          other.contentExtent == contentExtent &&
          other.devicePixelRatio == devicePixelRatio &&
          other.textDirection == textDirection;

  @override
  int get hashCode => Object.hash(
    baseline,
    viewInsets,
    contentExtent,
    devicePixelRatio,
    textDirection,
  );

  @override
  String toString() =>
      'PanelLayout($baseline, viewInsets: $viewInsets, contentExtent: '
      '${contentExtent?.px}, devicePixelRatio: $devicePixelRatio, '
      'textDirection: ${textDirection.name})';
}
