import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/render/render_panel.dart';

import '../fixtures/devices.dart';

// ============================================================================
// A render pipeline with no binding, no `WidgetTester` and no frames.
//
// DESIGN.md's own instruction for this layer is to drive `layout()` directly,
// and the reason is not purity for its own sake: the claims being tested are
// about *which render objects are dirty*, and a `pumpWidget` answers a question
// one layer up from that. A `PipelineOwner` needs no binding, so the whole
// render-object spec runs as plain `test`s, the way the geometry and model
// specs do.
//
// Two things here are load-bearing and neither is obvious.
//
// `guarded` — `RenderObject.layout` and `_layoutWithoutResize` both wrap
// `performResize`/`performLayout` in a try/catch and hand what they throw to
// `FlutterError.onError`. Outside a `testWidgets` zone that is `presentError`,
// which prints to the console and returns. So an unimplemented `performLayout`
// would be *swallowed*, and a test asserting nothing would pass while the code
// under it did not exist. Every entry into the pipeline goes through `guarded`.
//
// `PanelHost.parentUsesSize` — the default is `true` and the default child
// constraints are loose, and that is a fixture choice rather than a
// convenience. `_isRelayoutBoundary = !parentUsesSize || sizedByParent ||
// constraints.isTight || parent == null` (`rendering/object.dart:2847`), so a
// host that passed `parentUsesSize: false` or tight constraints would make the
// panel a relayout boundary whatever the panel did, and every boundary test
// under it would pass against an implementation that had never heard of
// `sizedByParent`. `boundary_premise_test.dart` is the proof that this fixture
// tells the two apart.
// ============================================================================

/// Runs [body] and rethrows whatever the render pipeline swallowed.
///
/// Rethrows the *first* reported error with its original stack, so the failure a
/// test reports is the failure that happened rather than the
/// `LateInitializationError` twenty lines downstream of it.
T guarded<T>(T Function() body) {
  final swallowed = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = swallowed.add;
  try {
    final result = body();
    if (swallowed.isNotEmpty) {
      Error.throwWithStackTrace(
        swallowed.first.exception,
        swallowed.first.stack ?? StackTrace.current,
      );
    }
    return result;
  } finally {
    FlutterError.onError = previous;
  }
}

/// A child that counts every question anyone asks it.
///
/// Three counters, because three different regressions look the same from
/// outside. [layouts] is the budget DESIGN.md §2.5 states — one per frame.
/// [dryLayouts] catches a content probe that runs when no detent asked for one,
/// which [layouts] cannot see because `getDryLayout` is not a layout.
/// [intrinsics] catches the measurement route this design refuses; it must stay
/// zero forever, and `stupid_simple_sheet` is where it does not.
///
/// Flutter 3.44.9 has no `RenderObject.debugLayoutCount` — DESIGN.md §2.5 cites
/// one — so the count is kept here, which is what the task specifies anyway: a
/// budget nobody asserts is a wish.
///
/// Extendable on purpose: the content that misbehaves — one that writes to the
/// model from inside its own `performLayout` — has to be counted like any other
/// child, and a second, uncounted box for it would be a fixture where the budget
/// assertions silently do not apply.
class CountingBox extends RenderBox {
  /// How many times this box has laid itself out.
  int layouts = 0;

  /// How many times it has been dry-laid-out.
  int dryLayouts = 0;

  /// How many intrinsic dimensions have been asked of it.
  int intrinsics = 0;

  /// The constraints of every layout, in order.
  final List<BoxConstraints> constraintsSeen = <BoxConstraints>[];

  /// The constraints of every dry layout, in order.
  ///
  /// Kept separately because the two are different questions: a layout is told
  /// how big to be, a measurement is asked how big it wants to be, and the
  /// constraint shapes that express those differ on the span axis.
  final List<BoxConstraints> dryConstraintsSeen = <BoxConstraints>[];

  /// The constraints of the most recent layout.
  BoxConstraints get lastConstraints => constraintsSeen.last;

  /// The constraints of the most recent dry layout.
  BoxConstraints get lastDryConstraints => dryConstraintsSeen.last;

  /// Forgets every count, so one rig can measure a second phase.
  void reset() {
    layouts = 0;
    dryLayouts = 0;
    intrinsics = 0;
    constraintsSeen.clear();
    dryConstraintsSeen.clear();
  }

  @override
  void performLayout() {
    layouts++;
    constraintsSeen.add(constraints);
    size = constraints.biggest;
  }

  /// True — content answers taps, the way a filled panel does.
  ///
  /// Without it the panel's own hit test would report a miss everywhere, and
  /// "a tap outside the panel falls through" would pass for the wrong reason.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    dryLayouts++;
    dryConstraintsSeen.add(constraints);
    return constraints.biggest;
  }

  @override
  double computeMinIntrinsicWidth(double height) => _intrinsic();

  @override
  double computeMaxIntrinsicWidth(double height) => _intrinsic();

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsic();

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsic();

  double _intrinsic() {
    intrinsics++;
    return 0;
  }
}

/// The parent a panel is measured against.
///
/// [parentUsesSize] and [childConstraints] are settable because they are the
/// fixture: the interesting case is a host that *does* read the panel's size and
/// *does not* dictate it, which is the only configuration where `sizedByParent`
/// is the reason the panel is a relayout boundary.
final class PanelHost extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  /// Hosts a child under [childConstraints].
  PanelHost({required this.childConstraints, this.parentUsesSize = true});

  /// What the child is laid out under.
  BoxConstraints childConstraints;

  /// Whether this host reads the child's size.
  bool parentUsesSize;

  /// How many times this host has laid itself out.
  int layouts = 0;

  @override
  void performLayout() {
    layouts++;
    child!.layout(childConstraints, parentUsesSize: parentUsesSize);
    size = constraints.constrain(
      parentUsesSize ? child!.size : childConstraints.biggest,
    );
  }
}

/// A whole render pipeline with one panel in it.
final class PanelRig {
  /// Builds and lays out a panel driven by [model].
  ///
  /// [viewport] is the size the host is given and, through loose child
  /// constraints, the largest size the panel may take — so it is the viewport
  /// every detent resolves against. It defaults to the iPhone 17 Pro every
  /// worked example in DESIGN.md is quoted on.
  PanelRig({
    required this.model,
    PanelMedia? media,
    Size viewport = const Size(402, 874),
    bool parentUsesSize = true,
    BoxConstraints? childConstraints,
    PanelAnchor anchor = PanelAnchor.bottom,
    EdgeAttachment attachment = EdgeAttachment.edgeAttached,
    PanelSizing sizing = PanelSizing.resize,
    bool measuresContent = false,
    CountingBox? content,
    bool withChild = true,
  }) : _viewport = viewport,
       content = content ?? CountingBox() {
    panel = RenderPanelViewport(
      model: model,
      media: media ?? portraitMedia,
      anchor: anchor,
      attachment: attachment,
      sizing: sizing,
      measuresContent: measuresContent,
      child: withChild ? this.content : null,
    );
    host = PanelHost(
      childConstraints: childConstraints ?? BoxConstraints.loose(viewport),
      parentUsesSize: parentUsesSize,
    )..child = panel;
    owner = PipelineOwner(onNeedVisualUpdate: () => visualUpdates++);
    guarded(() {
      host.attach(owner);
      host.layout(BoxConstraints.tight(viewport));
    });
  }

  /// The model the panel reads its extent from.
  final PanelModel model;

  /// The counting child, whether or not it was installed.
  final CountingBox content;

  /// The panel under test.
  late final RenderPanelViewport panel;

  /// The parent that measures it.
  late final PanelHost host;

  /// The pipeline the two live in.
  late final PipelineOwner owner;

  /// How many times anything asked for a frame.
  int visualUpdates = 0;

  Size _viewport;

  /// The viewport the panel is currently laid out in.
  Size get viewport => _viewport;

  /// Lays the tree out again, the way a frame would.
  ///
  /// Only dirty nodes run, which is the whole point: a call that lays nothing
  /// out is the correct outcome for a frame where nothing moved.
  void flush() => guarded(owner.flushLayout);

  /// Changes the space the panel is in — a rotation, or a window resize.
  void setViewport(Size viewport) {
    _viewport = viewport;
    host.childConstraints = BoxConstraints.loose(viewport);
    guarded(() {
      host.markNeedsLayout();
      host.layout(BoxConstraints.tight(viewport));
    });
  }

  /// Detaches and disposes everything this rig owns.
  ///
  /// The panel removes its model listener in `detach`, and a listener left on a
  /// model that outlives the tree is the leak this ordering exists to prevent —
  /// so the teardown is also a small assertion that `detach` is reachable.
  void dispose() {
    host.child = null;
    host.detach();
    panel.dispose();
    content.dispose();
    host.dispose();
  }
}

/// An iPhone 17 Pro held upright, with no keyboard.
///
/// Every number the render tests assert comes off this: a safe span of
/// 874 − 62 − 34 = 778, an attachment padding of 34, and therefore a `.medium`
/// frame of 0.56 × 778 + 34 = 469.68 and a `.full` frame of 812.
final PanelMedia portraitMedia = PanelMedia(
  viewPadding: kIPhone17Pro.viewPadding,
  viewInsets: EdgeInsets.zero,
  devicePixelRatio: kIPhone17Pro.devicePixelRatio,
  textDirection: TextDirection.ltr,
);

/// The same phone with the keyboard up.
///
/// `viewPadding` is unchanged and `viewInsets.bottom` is 336, which is the pair
/// that tells `viewPaddingOf` and `paddingOf` apart: a panel reading the wrong
/// one loses the 34pt home indicator off every detent the moment a field is
/// focused.
final PanelMedia keyboardMedia = PanelMedia(
  viewPadding: kIPhone17Pro.viewPadding,
  viewInsets: const EdgeInsets.only(bottom: 336),
  devicePixelRatio: kIPhone17Pro.devicePixelRatio,
  textDirection: TextDirection.ltr,
);

/// The frame span a detent of [value] takes on an edge-attached bottom sheet on
/// the 17 Pro — the detent value plus the 34pt it sits above.
double frameOnPro(double value) => value + kIPhone17Pro.viewPadding.bottom;

/// `.medium` on the 17 Pro, as a frame: 0.56 × 778 + 34.
///
/// Deliberately not rounded. It differs from the detent *value* (435.68), from
/// half the baseline (389), from half the viewport (437) and from the baseline
/// itself (778), so an assertion against it cannot also be satisfied by any of
/// the four plausible wrong answers.
final double mediumFrameOnPro = frameOnPro(0.56 * kIPhone17Pro.baseline);

/// `.full` on the 17 Pro, as a frame: 778 + 34 = 812, leaving the panel's top
/// edge at exactly the 62pt view padding.
final double fullFrameOnPro = frameOnPro(kIPhone17Pro.baseline);

/// The extent a [CountingBox] was laid out at along the span axis of a bottom
/// sheet.
double spanOf(BoxConstraints constraints) => constraints.maxHeight;
