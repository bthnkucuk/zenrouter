import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/shits.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/render/panel_viewport.dart';
import 'package:shits/src/render/render_panel.dart';

import '../fixtures/devices.dart';

// ============================================================================
// The rig for the widget layer, and one rule it follows: **it supplies the
// device and nothing else.**
//
// Every `Panel` in this suite is written out at its call site, with its detents
// and its policies named there. A harness that constructed the panel would be
// a harness that passed the defaults — and the defaults are half of what is
// under test here, since `Panel`'s job is to assemble a `PanelConfig` and a
// `PanelScrollLink` out of them. `scroll/harness.dart` records the same lesson
// from the other end: its three policies are only ever *assigned*, never passed
// to the constructor, so that `refresh_test.dart` is testing the shipped
// default rather than the harness's copy of it.
//
// The suite imports `package:shits/shits.dart` — the front door — for
// everything an app would write, and reaches into `src/` only for the two
// observation seams an app has no business having: the model behind the panel,
// and the render object that lays it out. If a test needs an internal to say
// what it means, that is worth noticing rather than hiding behind a re-export.
//
// The numbers are the iPhone 17 Pro's, for `render/harness.dart`'s reason: its
// plausible wrong answers are far apart. `.medium` is a detent value of 435.68
// and a frame of 469.68, against 389 for half the baseline, 437 for half the
// viewport, 778 for the baseline and 812 for `.full` — so an assertion that
// lands on 469.68 cannot also be satisfied by a panel that forgot `frameOf`, or
// one that resolved against the raw viewport.
// ============================================================================

/// The MVP's detent set: a 180pt peek, `.medium`, and `.full`.
const DetentSet kPeekSet = DetentSet([
  Detent.height(DetentValue(180)),
  Detent.medium,
  Detent.full,
]);

/// The peek's frame on the 17 Pro: 180 + 34.
const double kPeekFrame = 214.0;

/// `.medium`'s frame on the 17 Pro: 0.56 x 778 + 34 = 469.68.
final double kMediumFrame = 0.56 * kIPhone17Pro.baseline + 34.0;

/// `.full`'s frame on the 17 Pro: 778 + 34, leaving the top edge at 62.
const double kFullFrame = 812.0;

/// A software keyboard, as `MediaQueryData.viewInsets`.
///
/// 336pt is the iPhone 17 Pro's, and it is deliberately **larger than the peek
/// frame** (214): a keyboard that fits inside every detent would let a
/// derivation that forgot to clamp pass every row.
const EdgeInsets kKeyboard = EdgeInsets.only(bottom: 336);

/// Sizes the test surface to the phone every constant here is measured on.
///
/// Call it once, at the top of a file's `main()`. Without it the surface is
/// `flutter_test`'s 800x600, a panel takes its baseline from the constraints it
/// is laid out under, and every frame above is measured on a phone nobody
/// makes.
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

/// Puts [child] on the 17 Pro, with [viewInsets] over it.
///
/// `padding` is derived from the other two rather than passed, because that is
/// the relationship the framework itself maintains — `padding` is what is left
/// of `viewPadding` once `viewInsets` has eaten into it — and a fixture that let
/// the two be set independently could describe a device that does not exist,
/// which is exactly the state KB6 is about.
Widget onIPhone17Pro(
  Widget child, {
  EdgeInsets viewInsets = EdgeInsets.zero,
  TargetPlatform platform = TargetPlatform.iOS,
  TextDirection textDirection = TextDirection.ltr,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(
      size: kIPhone17Pro.size,
      viewPadding: kIPhone17Pro.viewPadding,
      padding: kIPhone17Pro.viewPadding.copyWith(
        bottom: (kIPhone17Pro.viewPadding.bottom - viewInsets.bottom).clamp(
          0.0,
          double.infinity,
        ),
      ),
      viewInsets: viewInsets,
      devicePixelRatio: kIPhone17Pro.devicePixelRatio,
    ),
    child: Directionality(
      textDirection: textDirection,
      // A sheet's content is a material surface in every app that has one, and
      // `TextField` refuses to build without one above it. Around the panel
      // rather than inside it, so that nothing about the panel's own
      // constraints changes.
      child: Material(child: child),
    ),
  ),
);

/// The render object the panel under test installed.
///
/// Finding it at all is the assertion that `Panel` installs the render layer;
/// `panel_test.dart` says so out loud in one test rather than leaving it
/// implied by every other one.
RenderPanelViewport boxIn(WidgetTester tester) =>
    tester.renderObject<RenderPanelViewport>(find.byType(PanelViewport));

/// The model the panel under test is driving.
///
/// Read off the render object rather than out of the state, because
/// `RenderPanelViewport.model` is already public — the widget layer's barrier,
/// handle and hit-test surfaces need it — and reaching into a private `State`
/// through `tester.state` would make every test here depend on a field name.
PanelModel modelIn(WidgetTester tester) => boxIn(tester).model;

/// Where the panel currently is, in logical pixels.
double extentIn(WidgetTester tester) => modelIn(tester).extent.px;

/// A list long enough to have somewhere to scroll to.
///
/// 60 rows of 48pt is 2880pt against a panel that is at most 812pt tall, so
/// `maxScrollExtent` is comfortably positive at every detent and does not move
/// when the panel resizes past a row boundary.
Widget longList({ScrollController? controller, bool? primary}) =>
    ListView.builder(
      controller: controller,
      primary: primary,
      itemCount: 60,
      itemExtent: 48,
      itemBuilder: (context, i) => Text('row $i'),
    );

/// A list with nothing to scroll — three rows in a sheet.
Widget shortList() => ListView.builder(
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

/// The three frames of [kPeekSet], resolved once.
final ResolvedDetents kPeekDetents = kPeekSet.resolve(
  kIPhone17Pro.panelBaseline(),
);

/// A panel state, including ones no live panel in this slice can reach.
///
/// [PanelMetrics] is public precisely for this. `EdgeOffset` is pinned at zero
/// until dismissal lands, and every quantity derived from it — the presentation
/// progress, the lift a sticky bottom bar needs — would otherwise be tested at
/// one value and shipped for a range. The centred-dialog row in
/// `scope_test.dart` is the one A2 is about, and there is no `CenterPlacement`
/// yet to produce it.
PanelMetrics metricsAt({
  required double extent,
  double edgeOffset = 0,
  double restingOffset = 0,
  EdgeInsets viewInsets = EdgeInsets.zero,
  ResolvedDetents? detents,
}) => PanelMetrics(
  extent: Extent(extent),
  edgeOffset: EdgeOffset(edgeOffset),
  restingOffset: EdgeOffset(restingOffset),
  detents: detents ?? kPeekDetents,
  layout: kIPhone17Pro.layout(viewInsets: viewInsets),
  anchor: PanelAnchor.bottom,
);

/// A mutable tally, for counting builds.
///
/// A plain box rather than a `ValueNotifier`, because incrementing a notifier
/// from inside a `build` would notify from inside a build.
final class Counter {
  /// How many times [counting]'s builder has run.
  int value = 0;
}

/// A widget that runs [builder] and counts how often it was asked to.
///
/// The instrument behind every "this did not rebuild" claim in this suite. It
/// is a `Builder`, so it has its own element and rebuilds only when *it* is
/// dirty: an inherited dependency it took, or a parent that rebuilt it. That is
/// the distinction the claims are about — a subtree handed the identical widget
/// is not rebuilt, and a subtree that depended on the panel's position is.
Widget counting(Counter counter, WidgetBuilder builder) => Builder(
  builder: (context) {
    counter.value++;
    return builder(context);
  },
);
