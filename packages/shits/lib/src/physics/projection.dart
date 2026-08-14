import 'package:flutter/physics.dart';
import 'package:meta/meta.dart';

import '../geometry/units.dart';

/// The fluid drag coefficient a released fling decelerates under.
///
/// 0.135 is Flutter's own iOS-lineage constant — `BouncingScrollSimulation`
/// builds its `FrictionSimulation` with it, under a comment tracing it to
/// `UIScrollViewDecelerationRateNormal` (0.998 per millisecond) and the identity
/// `0.998^1000 ≈ 0.135`. Landing distance works out to `0.49938 × velocity`,
/// which matches UIKit to four significant figures.
///
/// It is **not** 0.322, and it is not `ClampingScrollSimulation`, which models
/// Android's fling spline and lands somewhere else entirely.
/// `projection_test.dart` greps `lib/` for both.
const double kDecelerationDrag = 0.135;

/// Where a particle released at [from] with [velocity] px/s comes to rest.
///
/// The projection, not the path: a fling is decided the instant the finger
/// leaves, from where it *would* have stopped. Snapping to the detent nearest
/// this — rather than to the next one in the direction of travel — is what lets
/// a hard fling cross two detents, which is the behaviour a user has already
/// learned from every native scroll view.
///
/// A plain scalar in px, because the same projection is asked on two axes: the
/// extent axis, where the answer is a height, and the fused ballistic axis,
/// where it is a position across the panel and the list inside it. Neither is
/// the other, so the shared function is the one that is typed as neither, and
/// [projectFusedLanding] puts the fused type back on.
///
/// The result can be negative or past the tallest detent, and that is
/// information — it is how far past the end the fling wanted to go — so it is
/// deliberately not clamped and deliberately not an [Extent].
double projectLanding(double from, double velocity) =>
    FrictionSimulation(kDecelerationDrag, from, velocity).finalX;

/// [projectLanding] on the fused ballistic axis.
///
/// Exists so that the seam between the panel and its scrollable projects with
/// the same constant as the panel alone. Two call sites with the same literal in
/// them is how a fling ends up landing in one place and snapping to another.
@internal
FusedPosition projectFusedLanding(FusedPosition from, double velocity) =>
    FusedPosition(projectLanding(from.px, velocity));
