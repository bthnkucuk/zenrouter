import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

// ============================================================================
// The framework rule the whole render layer is built on, asserted against the
// framework rather than against us.
//
// `rendering/object.dart:2847`:
//   _isRelayoutBoundary = !parentUsesSize || sizedByParent
//                       || constraints.isTight || parent == null;
//
// Two of those four disjuncts are the panel's perf claim, and the other two are
// the reason a test of that claim is so easy to write blind: a host that passes
// `parentUsesSize: false`, or tight constraints, makes its child a relayout
// boundary whatever the child is. A boundary test written on such a host passes
// against an implementation that never heard of `sizedByParent`.
//
// So this file does two jobs. It pins the rule — if a Flutter upgrade moves it,
// the design's premise moved and this goes red before anything subtler does —
// and it proves that the fixture `render_panel_test.dart` uses tells the two
// implementations apart. Every test here has a partner asserting the *opposite*
// outcome from the opposite input. A claim with no such partner is a claim
// nobody checked.
//
// These are the only tests in `test/render/` that are green today: they have no
// subject in `lib/` yet.
// ============================================================================

/// A box whose two boundary-relevant decisions are parameters.
final class _Probe extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _Probe({required this.sized, required this.childConstraints});

  /// Whether this box's size comes from its constraints alone.
  final bool sized;

  /// What it lays its child out under. Always with `parentUsesSize: true`, so
  /// tightness is the only thing left that can make the child a boundary.
  final BoxConstraints childConstraints;

  @override
  bool get sizedByParent => sized;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.biggest;

  @override
  void performLayout() {
    if (!sized) size = constraints.biggest;
    child!.layout(childConstraints, parentUsesSize: true);
  }
}

({PanelHost host, _Probe probe, CountingBox child, PipelineOwner owner}) rig({
  required bool sized,
  required BoxConstraints childConstraints,
}) {
  final child = CountingBox();
  final probe = _Probe(sized: sized, childConstraints: childConstraints)
    ..child = child;
  // Loose, and read: the two disjuncts that are *not* under test are switched
  // off, so `sizedByParent` is the only thing that can carry the probe.
  final host = PanelHost(
    childConstraints: BoxConstraints.loose(const Size(402, 874)),
  )..child = probe;
  final owner = PipelineOwner(onNeedVisualUpdate: () {});
  guarded(() {
    host.attach(owner);
    host.layout(BoxConstraints.tight(const Size(402, 874)));
  });
  return (host: host, probe: probe, child: child, owner: owner);
}

void main() {
  const tight = BoxConstraints.tightFor(width: 402, height: 469.68);
  const spanTightOnly = BoxConstraints(
    minHeight: 469.68,
    maxHeight: 469.68,
    maxWidth: 402,
  );
  const loose = BoxConstraints(maxWidth: 402, maxHeight: 469.68);

  group('sizedByParent is what stops a per-frame relayout reaching the app', () {
    test(
      'a sizedByParent box under a loose, size-reading parent is a boundary',
      () {
        final r = rig(sized: true, childConstraints: tight);
        r.probe.markNeedsLayout();

        expect(r.probe.debugNeedsLayout, isTrue);
        expect(
          r.host.debugNeedsLayout,
          isFalse,
          reason:
              'this is the upward half of the claim: the panel marks itself dirty '
              'on every frame of a drag and the app tree above it never hears',
        );
      },
    );

    test(
      'and the same box without it is not — which is why the fixture is loose',
      () {
        final r = rig(sized: false, childConstraints: tight);
        r.probe.markNeedsLayout();

        expect(
          r.host.debugNeedsLayout,
          isTrue,
          reason:
              'the partner assertion. Without this, the test above would pass '
              'against a panel that had never heard of sizedByParent, because a '
              'tight or unread parent makes any child a boundary for free.',
        );
      },
    );
  });

  group(
    'a tight child constraint is what stops content relayout reaching the panel',
    () {
      test('a child laid out tight, with its size read, is a boundary', () {
        final r = rig(sized: true, childConstraints: tight);
        r.child.markNeedsLayout();

        expect(r.child.debugNeedsLayout, isTrue);
        expect(
          r.probe.debugNeedsLayout,
          isFalse,
          reason:
              'the downward half: a list that adds an item re-lays-out itself and '
              'nothing above it',
        );
      });

      test('and a child laid out loose is not', () {
        final r = rig(sized: true, childConstraints: loose);
        r.child.markNeedsLayout();

        expect(
          r.probe.debugNeedsLayout,
          isTrue,
          reason: 'the partner assertion for tightness',
        );
      });

      test('a constraint tight on the span axis alone is not tight at all', () {
        // `BoxConstraints.isTight` is `hasTightWidth && hasTightHeight`
        // (`rendering/box.dart:377`). DESIGN.md §2.5 names the helper that builds
        // the child's constraints `_tightOnSpanAxis`; implemented literally, that
        // name produces exactly this constraint, `isTight` is false, and the
        // downward half of the perf claim is quietly untrue.
        expect(spanTightOnly.isTight, isFalse);
        expect(spanTightOnly.hasTightHeight, isTrue);
        expect(spanTightOnly.hasTightWidth, isFalse);

        final r = rig(sized: true, childConstraints: spanTightOnly);
        r.child.markNeedsLayout();

        expect(
          r.probe.debugNeedsLayout,
          isTrue,
          reason:
              'pinning the cost of the literal reading, so that the panel giving '
              'its child both axes is a decision with a partner rather than a '
              'preference',
        );
      });
    },
  );

  test('and the pipeline swallows what performLayout throws', () {
    // The reason `guarded` exists, pinned. `RenderObject.layout` catches what
    // `performLayout` throws and hands it to `FlutterError.onError`, which
    // outside a `testWidgets` zone prints and returns. Without the capture, a
    // render object whose body is `throw UnimplementedError()` produces a green
    // test — which is the failure mode this whole directory is currently in.
    final reported = <Object>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => reported.add(details.exception);
    addTearDown(() => FlutterError.onError = previous);

    final child = _Throwing();
    // `parentUsesSize: false`, so the host does not go on to read a size the
    // failed child never set and report a second, derived error.
    final host = PanelHost(
      childConstraints: const BoxConstraints(),
      parentUsesSize: false,
    )..child = child;
    final owner = PipelineOwner(onNeedVisualUpdate: () {});
    host.attach(owner);
    host.layout(BoxConstraints.tight(const Size(402, 874)));

    expect(reported, hasLength(1));
    expect(reported.single, isA<UnimplementedError>());
  });
}

/// A box that fails the way an unwritten one does.
final class _Throwing extends RenderBox {
  @override
  void performLayout() => throw UnimplementedError();
}
