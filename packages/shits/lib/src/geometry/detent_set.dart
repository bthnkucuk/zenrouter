import 'dart:collection';

import 'package:meta/meta.dart';

import 'baseline.dart';
import 'detent.dart';
import 'units.dart';

/// The detents a panel may rest at, in authoring order.
///
/// A value type: two sets built independently from equal detents are equal, and
/// that is load-bearing. A panel re-snaps when its detent set *changes*, so a
/// set that compared unequal on every rebuild would snap the panel on every
/// rebuild. It is also why `Detent.custom` will require an explicit identity
/// when it lands — a closure is a fresh object every build.
@immutable
final class DetentSet {
  /// The set, in the order the author wrote it.
  ///
  /// The list is taken as given rather than copied, so that a `const DetentSet`
  /// stays const. A caller who hands over a growable list and then mutates it
  /// has changed the set behind its own equality.
  ///
  /// DESIGN.md also specifies `const DetentSet.single(d)`. Dart cannot express
  /// it: a list literal is not a constant expression, so no const constructor
  /// can wrap a parameter in one, and a non-const `single` would fail at exactly
  /// the const call site the design uses it at. `const DetentSet([d])` is the
  /// same thing and the same length.
  const DetentSet(this.detents);

  /// The detents, in authoring order.
  ///
  /// Authoring order is never index-arithmeticked: neighbours and nearest
  /// answers come from [ResolvedDetents], which is sorted. Mixing an index from
  /// one order with a lookup in the other is a shipped bug in the package this
  /// one is measured against, and the shapes here keep the two apart.
  final List<Detent> detents;

  /// Resolves every detent against [baseline], dropping the inactive ones, and
  /// converts each value into the frame that holds it.
  ///
  /// The conversion is `PanelBaseline.frameOf` and it happens exactly here, so
  /// the heights in a [ResolvedDetents] are frame spans throughout and a detent
  /// value never escapes this method. Allocates one list and sorts it once.
  /// Called on both the sizing and the committing pass of a layout, so it stays
  /// cheap.
  ///
  /// A set that resolves to nothing falls back to a full-height panel. That is
  /// **defined behaviour, in debug as well as release**: iOS accepts
  /// `sheet.detents = [.medium]` and shows a full sheet in compact height, so a
  /// panel that rotates into landscape with only a medium detent is a supported
  /// configuration and not a programmer error. Asserting on it hard-failed a
  /// legal app from inside a layout pass, on every frame after the rotation. An
  /// empty authored set lands in the same place by the same rule — one
  /// behaviour, not two, and both reachable by a test.
  ResolvedDetents resolve(PanelBaseline baseline) {
    final snaps = <(Detent, Extent)>[];
    for (final detent in detents) {
      final value = detent.resolve(baseline);
      if (value == null) continue;
      snaps.add((detent, baseline.frameOf(value)));
    }

    if (snaps.isEmpty) {
      final full = Detent.full;
      // `!` is total: FullDetent is the one kind that is never inactive — it is
      // the safe span, which every baseline has — which is what makes it the
      // only sound fallback here.
      snaps.add((full, baseline.frameOf(full.resolve(baseline)!)));
    }

    snaps.sort((a, b) => a.$2.compareTo(b.$2));
    return ResolvedDetents._(snaps, dismissible: false);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DetentSet) return false;
    if (other.detents.length != detents.length) return false;
    for (var i = 0; i < detents.length; i++) {
      if (other.detents[i] != detents[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(detents);

  @override
  String toString() => 'DetentSet($detents)';
}

/// A [DetentSet] resolved against one baseline: the heights a panel may actually
/// rest at right now, sorted ascending.
///
/// Sorted once, at construction, and no index ever crosses the sorted/unsorted
/// boundary — there is no way to ask this type for an authoring-order index, so
/// the "find the nearest in one list, step a neighbour in the other" bug cannot
/// be written against it.
@immutable
final class ResolvedDetents {
  ResolvedDetents._(List<(Detent, Extent)> snaps, {required this.dismissible})
    : assert(snaps.isNotEmpty, 'A panel with no resting height cannot exist.'),
      snaps = UnmodifiableListView(snaps);

  /// The active detents and their heights, ascending by height.
  ///
  /// A dismissed detent is not among them: it is a declaration that the panel
  /// may leave, not a height it may rest at, and it is reported by
  /// [dismissible].
  final List<(Detent, Extent)> snaps;

  /// Whether the panel may be dragged away entirely.
  ///
  /// Always false in this slice: `Detent.dismissed`, which is what switches it
  /// on, is not built yet. The field exists because the dismissal seam is
  /// specified to read it, and a seam that reads a literal `false` is harder to
  /// find later than one that reads this.
  final bool dismissible;

  /// The smallest resting height.
  Extent get min => snaps.first.$2;

  /// The largest resting height.
  Extent get max => snaps.last.$2;

  /// The distance between the smallest and largest resting heights, and so the
  /// panel's share of a fused ballistic axis. Zero for a single-detent panel.
  Extent get travel => max - min;

  /// The height [detent] resolved to, or null if it is not in this set or was
  /// inactive here.
  Extent? extentOf(Detent detent) {
    for (final snap in snaps) {
      if (snap.$1 == detent) return snap.$2;
    }
    return null;
  }

  /// The detent whose height is closest to [extent].
  ///
  /// Ties go to the shorter detent, deterministically, so a panel released
  /// exactly between two stops always resolves the same way.
  Detent nearestTo(Extent extent) {
    var best = snaps.first;
    var bestDistance = (best.$2.px - extent.px).abs();
    for (final snap in snaps.skip(1)) {
      final distance = (snap.$2.px - extent.px).abs();
      if (distance < bestDistance) {
        best = snap;
        bestDistance = distance;
      }
    }
    return best.$1;
  }

  /// The next resting height strictly above [extent], or null at the top.
  ///
  /// Strict, and exact: a panel resting a floating-point hair below its top
  /// detent would otherwise report room to grow. Callers that need a tolerance
  /// have the device pixel ratio and can use [Extent.isCloseTo]; this type does
  /// not, and will not guess one.
  Extent? neighbourAbove(Extent extent) {
    for (final snap in snaps) {
      if (snap.$2.px > extent.px) return snap.$2;
    }
    return null;
  }

  /// The next resting height strictly below [extent], or null at the bottom.
  Extent? neighbourBelow(Extent extent) {
    Extent? below;
    for (final snap in snaps) {
      if (snap.$2.px >= extent.px) break;
      below = snap.$2;
    }
    return below;
  }

  /// The height to open at, given a requested [detent].
  ///
  /// A null or unrecognised request opens at the smallest active detent. Apple's
  /// SDK header says an unknown selection shows the smallest; ours says the
  /// smallest *non-dismissed*, which is a deliberate divergence — a panel that
  /// opened dismissed would not be open.
  Extent select(Detent? detent) => extentOf(detent ?? snaps.first.$1) ?? min;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ResolvedDetents) return false;
    if (other.dismissible != dismissible) return false;
    if (other.snaps.length != snaps.length) return false;
    for (var i = 0; i < snaps.length; i++) {
      if (other.snaps[i] != snaps[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(snaps), dismissible);

  @override
  String toString() =>
      'ResolvedDetents(${[for (final (detent, extent) in snaps) '$detent: ${extent.px}'].join(', ')}, dismissible: $dismissible)';
}
