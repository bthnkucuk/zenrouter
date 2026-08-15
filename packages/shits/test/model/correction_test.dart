import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/baseline.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/layout.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/model/correction.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/physics/motion.dart';

import '../fixtures/devices.dart';

// ============================================================================
// Written before the activity leaves were finalised, which is the point of it.
//
// [_policyOf] is an exhaustive switch over the sealed `PanelActivity`
// hierarchy. A sixth leaf does not compile until it is given a case here, so a
// leaf that arrives without a policy is a build failure rather than a silent
// gap — and the case is also where its fixture gets written, which is the only
// half of "every leaf is covered" a compiler can enforce.
//
// The other job of this file is the merge rule DESIGN.md states: two leaves
// with identical corrections AND identical tick behaviour are one leaf with two
// names. It is asserted per branch, because the two drag leaves do collide on
// both counts and are still two classes — the branch they sit on is the
// difference, and it is the whole reason the hierarchy is split.
// ============================================================================

/// The three-stop sheet every case below is asked of: a 180pt peek, iOS's
/// medium, and full. Frames of 214, 469.68 and 812 on an iPhone 17 Pro.
const _peek = Detent.height(DetentValue(180));
const _sheet = DetentSet([_peek, Detent.medium, Detent.full]);
const _config = PanelConfig(detents: _sheet, initialDetent: Detent.medium);

/// An iPhone 17 Pro on its side: 402pt of height, which is compact, which is
/// where iOS deactivates the medium detent.
///
/// Built by hand rather than taken from the fixture table because the table
/// measures portrait sheets. The numbers are the same device's landscape safe
/// area — no top inset, a 21pt home indicator — and the only property the tests
/// below depend on is that `.medium` resolves to nothing here.
const _landscapeBaseline = PanelBaseline(
  safeSpan: Baseline(381),
  viewportSpan: ViewportExtent(402),
  attachedPadding: Extent(21),
  crossSpan: 874,
  isCompactHeight: true,
  spanAxis: Axis.vertical,
);

const _landscape = PanelLayout(
  baseline: _landscapeBaseline,
  viewInsets: EdgeInsets.zero,
  contentExtent: null,
  devicePixelRatio: 3,
  textDirection: TextDirection.ltr,
);

/// A scroll position that is only three numbers, which is all the model asks of
/// one.
final class _FakeScroll implements PanelScrollDriver {
  @override
  double pixels = 0;

  @override
  double minScrollExtent = 0;

  @override
  double maxScrollExtent = 2000;
}

/// What one leaf is expected to answer.
///
/// [correction] is a thunk and not a value so that this record can be built
/// while tests are being *registered* — the leaves that carry a live quantity
/// read it through a getter, and a getter that is not written yet must fail
/// inside a test rather than while the file is loading.
typedef _Policy = ({
  String name,
  LayoutCorrection Function() correction,
  bool isUserDriven,
  bool isTicking,
});

/// The content-resize protocol, one row per leaf.
///
/// Exhaustive over `PanelActivity`. This is the compile-time half of "adding a
/// leaf without a test is an error"; `every leaf has a fixture` below is the
/// half a compiler cannot do.
///
/// **Every payload here is a literal**, and deliberately not read back out of
/// the leaf it is checking. `hold(a.target)` and `settle(a.destination,
/// a.remaining)` are expectations built by asking the subject what it thinks,
/// so they pin the correction's *shape* — that an idle panel holds and a settle
/// settles — and never its contents: a `hold` of the wrong detent, or a settle
/// carrying the wrong clock, satisfies them exactly as well as the right one.
/// The literals below are the fixtures' own numbers, written once more, in the
/// other direction.
_Policy _policyOf(PanelActivity activity) => switch (activity) {
  // A parked panel is at a detent, not at a height, so a layout change means
  // re-resolving the detent.
  IdlePanelActivity() => (
    name: 'idle',
    correction: () => const LayoutCorrection.hold(Detent.medium),
    isUserDriven: false,
    isTicking: false,
  ),
  // The thing under the finger must not jump.
  DragPanelActivity() => (
    name: 'drag',
    correction: () => const LayoutCorrection.freeze(),
    isUserDriven: true,
    isTicking: false,
  ),
  // The destination moved; the time left to reach it did not. 500ms is
  // `PanelMotion.smooth`'s whole duration, because the fixture has not been
  // ticked.
  SettlingPanelActivity() => (
    name: 'settling',
    correction: () =>
        const LayoutCorrection.settle(Detent.full, Duration(milliseconds: 500)),
    isUserDriven: false,
    isTicking: true,
  ),
  // Same correction as `drag`, on the other branch. See the merge group below.
  ScrollDragActivity() => (
    name: 'scroll drag',
    correction: () => const LayoutCorrection.freeze(),
    isUserDriven: true,
    isTicking: false,
  ),
  // The fused axis was rescaled under the fling, so the landing is stale —
  // briefly. 1800 is the release, and it is still the release because the
  // fixture's clock is at zero.
  ScrollBallisticActivity() => (
    name: 'scroll ballistic',
    correction: () => const LayoutCorrection.resnap(ExtentVelocity(1800)),
    isUserDriven: false,
    isTicking: true,
  ),
};

void main() {
  final portrait = kIPhone17Pro.layout();
  final bigger = kIPhone17ProMax.layout();

  final portraitDetents = _sheet.resolve(portrait.baseline);
  final biggerDetents = _sheet.resolve(bigger.baseline);
  final landscapeDetents = _sheet.resolve(_landscape.baseline);

  final medium = portraitDetents.extentOf(Detent.medium)!;
  final full = portraitDetents.extentOf(Detent.full)!;

  /// One instance of every leaf, in the order [_policyOf] lists them.
  List<PanelActivity> everyLeaf() => [
    IdlePanelActivity(target: Detent.medium),
    DragPanelActivity(from: medium),
    SettlingPanelActivity(
      destination: Detent.full,
      from: medium,
      to: full,
      velocity: const ExtentVelocity(1200),
      motion: const PanelMotion.smooth(),
    ),
    ScrollDragActivity(position: _FakeScroll(), from: medium),
    ScrollBallisticActivity(
      position: _FakeScroll(),
      velocity: const ExtentVelocity(1800),
      resnapWindow: kResnapWindow,
    ),
  ];

  group('every leaf answers a correction, and answers it purely', () {
    for (final leaf in everyLeaf()) {
      final policy = _policyOf(leaf);

      test('${policy.name} asks for the correction its policy names', () {
        expect(leaf.onLayoutChanged, policy.correction());
      });

      test('${policy.name} asks for the same one twice', () {
        // A correction read during the sizing pass and again during the commit
        // has to be the same correction, or the two passes are answering
        // different questions however pure `resolve` is.
        expect(leaf.onLayoutChanged, leaf.onLayoutChanged);
      });

      test('${policy.name} resolves to the same extent twice', () {
        final correction = leaf.onLayoutChanged;
        expect(
          correction.resolve(portrait, medium, portraitDetents).px,
          correction.resolve(portrait, medium, portraitDetents).px,
        );
        // And across two separately built corrections that compare equal, which
        // is the property the model's debug tripwire actually relies on.
        expect(
          policy.correction().resolve(bigger, medium, biggerDetents).px,
          policy.correction().resolve(bigger, medium, biggerDetents).px,
        );
      });

      test('${policy.name} is asked and resolved without notifying '
          'anybody', () {
        // Through `dryApplyLayout` and not through a bare `resolve` call. A
        // `resolve` invoked from a test takes only value types and returns one,
        // so no implementation of it could reach a `ChangeNotifier` and the
        // assertion could not fail; the model's sizing pass is the path with
        // teeth, because it reads `onLayoutChanged` off the installed activity
        // and runs the debug tripwire over it. It is also the call that happens
        // *before* the child is laid out, which is the reading where a listener
        // that rebuilt would rebuild a widget that is mid-layout.
        final model = PanelModel(config: _config, layout: portrait);
        var notifications = 0;
        model.addListener(() => notifications++);
        model.beginActivity(leaf);
        // Installing an activity is a change and is allowed to notify. Reading
        // what it wants from a layout is not.
        notifications = 0;

        expect(model.dryApplyLayout(portrait).px, isNot(isNaN));
        expect(model.dryApplyLayout(bigger).px, isNot(isNaN));
        expect(notifications, 0);
      });

      test('${policy.name} reports whether a finger and a clock drive it', () {
        expect(leaf.isUserDriven, policy.isUserDriven);
        expect(leaf.isTicking, policy.isTicking);
      });
    }

    test('every leaf has a fixture, and there are five of them', () {
      final leaves = everyLeaf();
      expect(
        leaves.map((leaf) => leaf.runtimeType).toSet().length,
        leaves.length,
        reason: 'two fixtures of the same leaf, so one leaf is untested',
      );
      // The count is a literal because it is the half [_policyOf] cannot check.
      // The compiler refuses to build a sixth leaf without a case up there; it
      // cannot refuse to *run* one without an instance down here, and Dart has
      // no way to enumerate a sealed hierarchy at runtime. So a leaf added with
      // a policy and no fixture, or a fixture deleted from under the loop
      // above, is caught here and nowhere else — the per-leaf tests are
      // generated from this list, and a shorter list is quietly fewer tests.
      expect(
        leaves,
        hasLength(5),
        reason:
            'DESIGN.md §1.2 lists nine activity types and this slice ships '
            'five: Ballistic is folded into the settle, and ScrollHold waits '
            'for the layer that constructs it',
      );
      expect(leaves.whereType<SelfDrivenActivity>(), hasLength(3));
      expect(leaves.whereType<ScrollDrivenActivity>(), hasLength(2));
    });
  });

  group('the merge rule', () {
    test('no two leaves on one branch ask for the same correction', () {
      // DESIGN.md: two leaves with identical corrections and identical tick
      // behaviour are one leaf with two names. Within a branch there is nothing
      // else to tell them apart, so within a branch the rule is absolute.
      for (final branch in [
        everyLeaf().whereType<SelfDrivenActivity>().toList(),
        everyLeaf().whereType<ScrollDrivenActivity>().toList(),
      ]) {
        final corrections = [
          for (final leaf in branch) _policyOf(leaf).correction(),
        ];
        expect(
          corrections.toSet().length,
          corrections.length,
          reason: 'two leaves of one branch want the same thing: $corrections',
        );
      }
    });

    test('the two drags do collide, and the branch is what keeps them apart', () {
      // This is the one pair the rule as written would merge, and merging them
      // means one class with a nullable "who is driving me" — which is the
      // smooth_sheets defect (`lib/src/scrollable.dart:147-152`) this hierarchy
      // is shaped to prevent. The rule needs the qualifier "within a branch".
      final drag = DragPanelActivity(from: medium);
      final scrollDrag = ScrollDragActivity(
        position: _FakeScroll(),
        from: medium,
      );

      expect(drag.onLayoutChanged, scrollDrag.onLayoutChanged);
      expect(drag.isUserDriven, scrollDrag.isUserDriven);
      expect(drag.isTicking, scrollDrag.isTicking);

      // And the difference that earns them two names: one of them can always
      // say where the list inside the panel is scrolled to, with no null check.
      expect(scrollDrag.position.pixels, 0);
      expect(drag, isNot(isA<ScrollDrivenActivity>()));
    });
  });

  group('a drag freezes the pixels', () {
    const freeze = LayoutCorrection.freeze();

    test('and does not move them when the layout grows', () {
      expect(freeze.resolve(bigger, medium, biggerDetents).px, medium.px);
    });

    test('nor when it shrinks under the finger', () {
      // A keyboard opening mid-drag, and a rotation, are the same event here.
      expect(
        freeze.resolve(_landscape, medium, landscapeDetents).px,
        medium.px,
      );
    });

    test('nor when the finger is past the top detent', () {
      // Deliberately unclamped: 900 is 88pt above full's 812, which is where
      // the rubber band legitimately puts a panel a finger is pulling on.
      // Clamping here is the yank the correction exists to prevent.
      expect(
        freeze.resolve(portrait, const Extent(900), portraitDetents).px,
        900.0,
      );
    });

    test('nor below the smallest one', () {
      expect(
        freeze.resolve(portrait, const Extent(120), portraitDetents).px,
        120.0,
      );
    });
  });

  group('idle re-resolves its detent', () {
    const hold = LayoutCorrection.hold(Detent.medium);

    test('against the layout it is handed', () {
      expect(
        hold.resolve(portrait, medium, portraitDetents).px,
        closeTo(0.56 * 778 + 34, 1e-9),
      );
      expect(
        hold.resolve(bigger, medium, biggerDetents).px,
        closeTo(0.56 * 860 + 34, 1e-9),
      );
    });

    test('and ignores where the panel currently is', () {
      // The detent is the state. The height is only what it meant last pass.
      for (final current in const [Extent(0), Extent(500), Extent(9000)]) {
        expect(
          hold.resolve(portrait, current, portraitDetents).px,
          closeTo(medium.px, 1e-9),
        );
      }
    });

    test('and a keyboard cannot move it', () {
      // KB6, proved by construction: `viewInsets` is on the layout and not on
      // the baseline, so a detent has no way to see it. 336pt is a full iPhone
      // keyboard.
      final withKeyboard = kIPhone17Pro.layout(
        viewInsets: const EdgeInsets.only(bottom: 336),
      );
      expect(
        hold.resolve(withKeyboard, medium, portraitDetents).px,
        closeTo(medium.px, 1e-9),
      );
    });

    test('and falls back to the nearest survivor when it goes inactive', () {
      // Landscape is compact height, where iOS deactivates `.medium`. The
      // survivors are the peek at 201 and full at 402.
      expect(landscapeDetents.extentOf(Detent.medium), isNull);
      expect(
        hold.resolve(_landscape, medium, landscapeDetents).px,
        402.0,
        reason: 'from 469.68 the nearest survivor is full',
      );
      expect(
        hold.resolve(_landscape, const Extent(210), landscapeDetents).px,
        201.0,
        reason: 'nearest, not largest, or this would be 402 as well',
      );
    });
  });

  group('a settle carries the time that is left', () {
    test('and leaves the panel where the spring already put it', () {
      const settle = SettleWithin(Detent.full, Duration(milliseconds: 320));
      expect(
        settle,
        const LayoutCorrection.settle(Detent.full, Duration(milliseconds: 320)),
      );
      expect(
        settle.resolve(bigger, const Extent(600), biggerDetents).px,
        600.0,
      );
      expect(settle.destination, Detent.full);
      expect(settle.remaining, const Duration(milliseconds: 320));
    });

    test('and the remaining time shrinks as the settle runs', () {
      // This is what makes repeated corrections converge. A re-seed that
      // restarted the full duration would never arrive under content that keeps
      // changing.
      final settling = SettlingPanelActivity(
        destination: Detent.full,
        from: medium,
        to: full,
        velocity: ExtentVelocity.zero,
        motion: const PanelMotion.smooth(),
      );
      expect(settling.remaining, const PanelMotion.smooth().duration);

      settling.tick(const Duration(milliseconds: 100));
      expect(settling.remaining, const Duration(milliseconds: 400));
      expect(settling.onLayoutChanged, isA<SettleWithin>());
      expect(
        settling.onLayoutChanged,
        const LayoutCorrection.settle(Detent.full, Duration(milliseconds: 400)),
      );

      settling.tick(const Duration(seconds: 5));
      expect(
        settling.remaining,
        Duration.zero,
        reason: 'floored, never negative — a spring of −4.5s is not a motion',
      );
    });
  });

  group('and a settle that has run out of it has arrived', () {
    test('so it resolves to its destination, not to where the spring got '
        'to', () {
      // The commit half may not move the extent — the sizing pass has already
      // been believed — so a settle whose time is spent can only be finished by
      // the half that is allowed to answer with a height. Answering `current`
      // here parked the panel at a detent it had never moved to and left it
      // there for good: the activity that would have carried it is replaced in
      // the same commit, and every pass after that resolves the detent the
      // panel is already claimed to be at.
      const settle = LayoutCorrection.settle(Detent.full, Duration.zero);
      expect(
        settle.resolve(portrait, const Extent(808), portraitDetents).px,
        full.px,
      );
      expect(
        settle.resolve(_landscape, const Extent(808), landscapeDetents).px,
        402.0,
        reason: 'and to where the new layout puts it, which is the whole point',
      );
    });

    test('and the whole sub-millisecond band is an arrival, not a very short '
        'spring', () {
      // `SpringDescription.withDurationAndBounce` measures whole milliseconds
      // and asserts above zero, so everything in (0, 1ms) is a spring that
      // cannot be built at all: a debug refusal from inside a layout pass, and
      // in release an infinite stiffness that writes NaN every frame and never
      // reports itself done.
      for (final remaining in const [
        Duration.zero,
        Duration(microseconds: 1),
        Duration(microseconds: 999),
      ]) {
        final settle = SettleWithin(Detent.full, remaining);
        expect(settle.hasArrived, isTrue, reason: '$remaining');
        expect(
          settle.resolve(portrait, const Extent(808), portraitDetents).px,
          full.px,
          reason: '$remaining',
        );
      }

      const shortest = SettleWithin(Detent.full, kMinimumSettleDuration);
      expect(shortest.hasArrived, isFalse);
      expect(
        shortest.resolve(portrait, const Extent(808), portraitDetents).px,
        808.0,
        reason: 'one millisecond is the shortest spring there is, and it runs',
      );
    });

    test('and it takes hold\'s fallback when its destination went '
        'inactive', () {
      // The same expression, so the two cannot answer differently: a settle
      // finishing into a compact-height layout lands where an idle panel
      // holding the same detent would.
      const settle = LayoutCorrection.settle(Detent.medium, Duration.zero);
      expect(landscapeDetents.extentOf(Detent.medium), isNull);
      expect(
        settle.resolve(_landscape, const Extent(380), landscapeDetents).px,
        402.0,
      );
      expect(
        settle.resolve(_landscape, const Extent(210), landscapeDetents).px,
        201.0,
        reason: 'nearest, not smallest, exactly as hold answers it',
      );
    });
  });

  group('a ballistic re-snaps, briefly', () {
    ScrollBallisticActivity ballistic({Duration window = kResnapWindow}) =>
        ScrollBallisticActivity(
          position: _FakeScroll(),
          velocity: const ExtentVelocity(1800),
          resnapWindow: window,
        );

    test('inside the window', () {
      final fling = ballistic();
      expect(fling.isResnapping, isTrue);
      expect(fling.onLayoutChanged, isA<ResnapBallistic>());

      fling.tick(const Duration(milliseconds: 100));
      expect(fling.isResnapping, isTrue);
    });

    test('and stops after it', () {
      final fling = ballistic();
      fling.tick(const Duration(milliseconds: 200));
      expect(fling.isResnapping, isFalse);
      expect(
        fling.onLayoutChanged,
        const LayoutCorrection.freeze(),
        reason: 'a fling that kept re-choosing would commit to nothing',
      );
    });

    test('and a zero window never re-snaps at all', () {
      // The other end of the policy, which is the only thing that makes it one.
      final fling = ballistic(window: Duration.zero);
      expect(fling.isResnapping, isFalse);
      expect(fling.onLayoutChanged, const LayoutCorrection.freeze());
    });

    test('and re-snapping does not move the panel this pass', () {
      // The projection moved, not the panel. Moving the panel too is a jump in
      // the middle of a fling.
      const resnap = LayoutCorrection.resnap(ExtentVelocity(1800));
      expect(
        resnap.resolve(bigger, const Extent(600), biggerDetents).px,
        600.0,
      );
      expect(
        resnap.resolve(_landscape, const Extent(600), landscapeDetents).px,
        600.0,
      );
    });

    test('and it carries the live velocity, not the released one', () {
      final fling = ballistic();
      final atRelease = fling.onLayoutChanged;
      fling.tick(const Duration(milliseconds: 100));
      expect(
        fling.onLayoutChanged,
        isNot(atRelease),
        reason: 're-projecting from the throw would overshoot what is left',
      );
    });
  });

  group('a correction is a value', () {
    test('two of a kind are equal, and carry their payload into it', () {
      expect(const LayoutCorrection.freeze(), const LayoutCorrection.freeze());
      expect(
        const LayoutCorrection.hold(Detent.medium),
        const LayoutCorrection.hold(Detent.medium),
      );
      expect(
        const LayoutCorrection.hold(Detent.medium),
        isNot(const LayoutCorrection.hold(Detent.full)),
      );
      expect(
        const LayoutCorrection.settle(Detent.full, Duration(milliseconds: 1)),
        isNot(
          const LayoutCorrection.settle(Detent.full, Duration(milliseconds: 2)),
        ),
      );
      expect(
        const LayoutCorrection.resnap(ExtentVelocity(1)),
        isNot(const LayoutCorrection.resnap(ExtentVelocity(2))),
      );
      expect(
        const LayoutCorrection.freeze(),
        isNot(const LayoutCorrection.hold(Detent.full)),
      );
      expect(const LayoutCorrection.freeze(), isNot(const Object()));
    });

    test(
      'and hash with it, so a set of corrections is a set of behaviours',
      () {
        expect(
          const LayoutCorrection.freeze().hashCode,
          const LayoutCorrection.freeze().hashCode,
        );
        final corrections = <LayoutCorrection>[
          const LayoutCorrection.freeze(),
          const LayoutCorrection.freeze(),
          const LayoutCorrection.hold(Detent.full),
        ];
        expect(corrections.toSet().length, 2);
      },
    );

    test('and say which one they are', () {
      expect(
        const LayoutCorrection.freeze().toString(),
        'LayoutCorrection.freeze()',
      );
      expect(
        const LayoutCorrection.hold(Detent.medium).toString(),
        'LayoutCorrection.hold(Detent.medium)',
      );
      expect(
        const LayoutCorrection.settle(
          Detent.full,
          Duration(milliseconds: 320),
        ).toString(),
        startsWith('LayoutCorrection.settle(Detent.full'),
      );
      expect(
        const LayoutCorrection.resnap(ExtentVelocity(1800)).toString(),
        contains('1800'),
      );
    });
  });
}
