import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/render/panel_viewport.dart';
import 'package:shits/src/scroll/attachment.dart';
import 'package:shits/src/scroll/link.dart';
import 'package:shits/src/scroll/policy.dart';

import '../fixtures/devices.dart';
import 'package:shits/src/physics/momentum.dart';

// ============================================================================
// Two rigs, because the layer has two halves and only one of them needs a
// device.
//
// The **arbitration** is a pure function of three scalars — where the content
// is and where its ends are — and of a model that imports no binding. So
// `split_test.dart`, `refresh_test.dart` and `fused_axis_test.dart` are plain
// `test`s over [FakeContent] and [linkAt], with no `pumpWidget`, no gesture and
// no frame. That is the same discipline the geometry, physics and model layers
// are held to, and it is what makes an arbitration matrix cheap enough to
// enumerate exhaustively instead of sampling.
//
// The **plumbing** — capture, escapes, the fused fling as it actually runs —
// needs a real `Scrollable`, a real gesture and a real ticker, and that is
// [panel] and `tester`.
//
// The detent set every test uses is the MVP's, and its three frames are chosen
// so no assertion against one can be satisfied by a plausible wrong answer:
// 214, 469.68 and 812 are pairwise far apart, none is half of another, and
// 469.68 is not 435.68 (the detent *value*), 389 (half the baseline), 437 (half
// the viewport) or 778 (the baseline).
// ============================================================================

/// The MVP's detent set: a 180pt peek, `.medium`, and `.full`.
const DetentSet kPeekSet = DetentSet([
  Detent.height(DetentValue(180)),
  Detent.medium,
  Detent.full,
]);

/// A single-detent set, for S5 — the case where "no neighbour above" is not a
/// special case but the only case.
const DetentSet kSingleSet = DetentSet([Detent.full]);

/// The peek's frame on the 17 Pro: 180 + 34.
const double kPeekFrame = 214.0;

/// `.medium`'s frame on the 17 Pro: 0.56 × 778 + 34.
final double kMediumFrame = 0.56 * kIPhone17Pro.baseline + 34.0;

/// `.full`'s frame on the 17 Pro: 778 + 34, leaving the top edge at 62.
const double kFullFrame = 812.0;

/// A [PanelScrollDriver] whose three scalars are fields.
///
/// The whole of what the arbiter is allowed to know about a scrollable, which
/// is why the arbitration can be specified without one. Mutable, because a
/// split test's second act is "and now the list has moved".
final class FakeContent implements PanelScrollDriver {
  /// A list of [maxScrollExtent] px sitting at [pixels].
  FakeContent({
    this.pixels = 0,
    this.minScrollExtent = 0,
    this.maxScrollExtent = 2000,
  });

  /// A list with nothing to scroll — content shorter than its viewport.
  ///
  /// Not a degenerate case: it is what a three-row sheet is, and it is the state
  /// in which the panel must absorb every delta rather than handing a share to
  /// a list that cannot use it.
  FakeContent.short() : pixels = 0, minScrollExtent = 0, maxScrollExtent = 0;

  @override
  double pixels;

  @override
  double minScrollExtent;

  @override
  double maxScrollExtent;

  @override
  String toString() =>
      'FakeContent(pixels: $pixels, [$minScrollExtent, $maxScrollExtent])';
}

/// A model on the 17 Pro, parked at [extent].
///
/// [extent] is written through `applyExtent` rather than through a settle,
/// because these tests are about the split and not about how the panel got
/// where it is — and a settle would install an activity that the split has no
/// opinion about.
///
/// **It is also parked at the *detent* that height belongs to, and that half is
/// not cosmetic.** An idle panel is at a detent rather than at a height, so the
/// first layout pass answers `LayoutCorrection.hold(target)` and moves the panel
/// to wherever that detent now is. Writing 812 into a model whose idle target is
/// still the smallest detent gives a panel that measures 812 until it is put in
/// a tree and 214 one pump later — so every widget test asking for a fully open
/// panel was arbitrating for a peek, and the two that assert "smaller than
/// medium" were passing because 214 is smaller than everything.
///
/// A height that is not a detent — 300, or a spring's last tenth of a pixel —
/// keeps the smallest target and is only ever used by the plain `test`s above,
/// which never lay out.
PanelModel modelAt(
  double extent, {
  DetentSet detents = kPeekSet,
  TextDirection textDirection = TextDirection.ltr,
  PanelAnchor anchor = PanelAnchor.bottom,
}) {
  final layout = kIPhone17Pro.layout(
    anchor: anchor,
    textDirection: textDirection,
  );
  final resolved = detents.resolve(layout.baseline);
  final at = Extent(extent);
  final model = PanelModel(
    config: PanelConfig(
      detents: detents,
      initialDetent: [
        for (final (detent, height) in resolved.snaps)
          if (height.isCloseTo(
            at,
            devicePixelRatio: kIPhone17Pro.devicePixelRatio,
          ))
            detent,
      ].firstOrNull,
    ),
    layout: layout,
  );
  model.applyExtent(at);
  return model;
}

/// A link over a panel parked at [extent].
///
/// **The three policies are nullable and are only ever *assigned*, never passed
/// to the constructor, and that is the point of the shape.** A harness that
/// passed `PanelScrollPolicy.resizesFromEdge` as its own default would mean the
/// constructor's default was never read by anything in this suite: swapping
/// `PanelRefreshPolicy.whenFullyOpen` for `never` in `link.dart` would leave
/// `refresh_test.dart` — whose entire subject is that default — green, and no
/// `RefreshIndicator` in any sheet would ever fire. So every row that does not
/// name a policy arbitrates under the shipped one, and the three rows in
/// `split_test.dart`'s "the shipped defaults" group read them back deliberately.
///
/// Assigned rather than passed because the three are mutable fields — a
/// placement change rebuilds the widget above and not the link — so a test can
/// ask for a policy without the constructor ever being told one.
PanelScrollLink linkAt(
  double extent, {
  DetentSet detents = kPeekSet,
  PanelAnchor anchor = PanelAnchor.bottom,
  TextDirection textDirection = TextDirection.ltr,
  PanelScrollPolicy? scrollPolicy,
  PanelRefreshPolicy? refreshPolicy,
  MomentumCarry? momentumCarry,
}) {
  final link = PanelScrollLink(
    model: modelAt(
      extent,
      detents: detents,
      anchor: anchor,
      textDirection: textDirection,
    ),
    anchor: anchor,
  );
  if (scrollPolicy != null) link.scrollPolicy = scrollPolicy;
  if (refreshPolicy != null) link.refreshPolicy = refreshPolicy;
  if (momentumCarry != null) link.momentumCarry = momentumCarry;
  return link;
}

/// A drag delta, in the units `ScrollPosition.applyUserOffset` receives.
///
/// Named rather than written inline because the sign is the thing that goes
/// wrong: **positive is the finger moving toward the content's start**, which
/// for a bottom sheet is downward and shrinking. Every test that says
/// `dragDown(30)` is saying what the finger did, not what the number is.
double dragDown(double px) => px;

/// A finger moving away from the content's start — up, for a bottom sheet.
double dragUp(double px) => -px;

// ============================================================================
// The widget rig.
//
// "One fling, one ticker" is counted with `SchedulerBinding.transientCallbackCount`
// rather than by intercepting the vsync: `FusedBallisticActivity` takes its
// provider from `ScrollContext.vsync`, which is the `Scrollable`'s own state and
// is not reachable from outside it. The binding's count is the number of tickers
// actually running, which is the claim rather than a proxy for it.
// ============================================================================

/// Records the scroll notifications a gesture produced, in order.
///
/// A trace rather than a count, because the interesting failures are about
/// *sequence*: a handoff implemented as two activities ends one and starts
/// another mid-fling, and the tell is a `ScrollEndNotification` followed by a
/// `ScrollStartNotification` with no finger in between.
final class NotificationTrace {
  /// Every notification seen, oldest first.
  final seen = <ScrollNotification>[];

  /// The types, in order — what an assertion is usually written against.
  List<Type> get types => [for (final n in seen) n.runtimeType];

  /// Whether a `ScrollEnd` is immediately followed by a `ScrollStart`.
  bool get hasSpuriousRestart {
    for (var i = 0; i + 1 < seen.length; i++) {
      if (seen[i] is ScrollEndNotification &&
          seen[i + 1] is ScrollStartNotification) {
        return true;
      }
    }
    return false;
  }

  /// Wraps [child] so every notification from it is recorded.
  Widget listen(Widget child) => NotificationListener<ScrollNotification>(
    onNotification: (notification) {
      // Depth zero only: a nested list would otherwise put its own trace into
      // the outer one and every sequence assertion would be about both.
      if (notification.depth == 0) seen.add(notification);
      return false;
    },
    child: child,
  );
}

/// Sizes the test surface to the phone every constant in this suite is measured
/// on. Call it once, at the top of a file's `main()`.
///
/// **Without it the widget half of this suite is measured on something else.**
/// `flutter_test`'s surface is 800×600, and a panel takes its baseline from the
/// constraints it is laid out under rather than from the ambient `MediaQuery` —
/// so `.full` resolves to 538 instead of 812, `.medium` to 316.24 instead of
/// 469.68, and [kInsidePanel] lands 174pt below the bottom of the window where
/// every gesture in the file hits nothing at all. The pure `test`s are unaffected
/// because they resolve against [kIPhone17Pro] directly; the `testWidgets` were
/// arbitrating for a phone nobody makes.
void useIPhone17Pro() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .implicitView!;
    view.physicalSize = kIPhone17Pro.size * kIPhone17Pro.devicePixelRatio;
    view.devicePixelRatio = kIPhone17Pro.devicePixelRatio;
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .implicitView!
        .reset();
  });
}

/// A whole panel with [content] inside it, on the 17 Pro.
///
/// The content is captured through `PanelScrollAttachment`, which is the only
/// thing the app is asked to have done — `capture_test.dart` is the measurement
/// that a bare `ListView` under it takes the panel's controller on every
/// platform, so nothing here re-proves capture and everything here assumes it.
///
/// `PanelViewport` is what gives the panel a height, and it is under the
/// attachment rather than over it so the list's own viewport is the panel's
/// visible extent — which is the acceptance property the whole design rests on.
Widget panel({
  required PanelModel model,
  required PanelScrollLink link,
  required Widget content,
  TargetPlatform platform = TargetPlatform.iOS,
  TextDirection textDirection = TextDirection.ltr,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(
      size: kIPhone17Pro.size,
      viewPadding: kIPhone17Pro.viewPadding,
      padding: kIPhone17Pro.viewPadding,
      devicePixelRatio: kIPhone17Pro.devicePixelRatio,
    ),
    child: Directionality(
      textDirection: textDirection,
      child: PanelViewport(
        model: model,
        child: PanelScrollAttachment(
          // A sheet's content is a material surface in every app that has one,
          // and `TextField` refuses to build without one above it. Inside the
          // attachment rather than around the panel, so nothing about the
          // capture, the behaviour or the panel's own constraints changes —
          // this is the content, and the content is what an app puts here.
          link: link,
          child: Material(child: content),
        ),
      ),
    ),
  ),
);

/// A list long enough to have somewhere to scroll to.
///
/// 60 rows of 48pt is 2880pt against a panel that is at most 812pt tall, so
/// `maxScrollExtent` is comfortably positive at every detent and does not move
/// when the panel resizes past a row boundary.
Widget longList({
  ScrollController? controller,
  bool? primary,
  ScrollPhysics? physics,
}) => ListView.builder(
  controller: controller,
  primary: primary,
  physics: physics,
  itemCount: 60,
  itemExtent: 48,
  itemBuilder: (context, i) => Text('row $i'),
);

/// A list with nothing to scroll — three rows in a sheet.
///
/// The widget form of [FakeContent.short], and not a degenerate case: it is the
/// state in which the panel must absorb every delta rather than handing a share
/// to a list that cannot use it, and the only one in which the panel can be
/// dragged past its largest detent at all.
Widget shortList({ScrollPhysics? physics}) => ListView.builder(
  physics: physics,
  itemCount: 3,
  itemExtent: 48,
  itemBuilder: (context, i) => Text('row $i'),
);

/// The point a gesture on the panel's content starts from.
///
/// Inside the panel at every detent this suite uses — the smallest frame is
/// 214pt, so 100pt above the bottom edge is inside all three — and away from
/// the edges, so a drag from here is never mistaken for a system back gesture.
const Offset kInsidePanel = Offset(200, 774);
