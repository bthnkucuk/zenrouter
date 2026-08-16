import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/shits.dart';

import '../fixtures/devices.dart';
import 'harness.dart';

// ============================================================================
// DESIGN.md A6.6: the keyboard is ours, not the app's.
//
// The row this file is the acceptance for is #18 `textfield_with_multiple_stops`,
// which the package it is ported from solves at the call site:
//
//     padding: EdgeInsets.only(
//       bottom: MediaQuery.viewInsetsOf(context).bottom,
//     ),
//
// A6.6 rules that a port reproducing that has failed the row. It is also wrong
// as often as it is right, and the two halves of this file are the two reasons:
//
//   1. The screen's insets stop describing the content the moment the panel is
//      not full height. A `.medium` sheet's top edge is 404pt below the status
//      bar; its content's `viewPadding.top` is 0, not 62.
//   2. The detents may not move when the keyboard opens. `PanelBaseline` cannot
//      see `viewInsets` by construction (A1, KB6), so that is proved rather
//      than asserted — but a *widget* can still break it, by wrapping the panel
//      in the very `Padding` A6.6 forbids the app to write. That is the last
//      group here.
//
// The derivation is driven directly as well as through a panel, because the
// geometries that discriminate it — a panel above its largest detent, a panel
// clear of its attachment edge — are ones this slice's live panel cannot reach.
// ============================================================================

/// The window, as the panel sees it before it re-measures anything.
MediaQueryData _window({EdgeInsets viewInsets = EdgeInsets.zero}) =>
    MediaQueryData(
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
    );

/// The rect a bottom sheet of [extent] occupies on the 17 Pro.
Rect _sheetRect(double extent) =>
    Rect.fromLTRB(0, kIPhone17Pro.size.height - extent, 402, 874);

void main() {
  useIPhone17Pro();

  group('the derivation, at geometries a live panel cannot reach yet', () {
    test('an inset the panel does not touch is not the content\'s', () {
      // A `.medium` sheet is 469.68 tall, so its top edge is at 404.32 — 342pt
      // clear of the 62pt status bar. Its content has no top inset. Forwarding
      // the window's would put a `SafeArea` 62pt of empty space below the
      // sheet's own top edge, which is the commonest visible symptom of an
      // un-re-derived MediaQuery.
      final derived = PanelMediaQuery.deriveFrom(
        _window(),
        panel: _sheetRect(kMediumFrame),
        viewport: kIPhone17Pro.size,
      );

      expect(derived.viewPadding.top, 0);
      expect(
        derived.viewPadding.bottom,
        34,
        reason: 'the panel is on that edge',
      );
      expect(derived.size.width, 402);
      expect(
        derived.size.height,
        closeTo(kMediumFrame, 1e-9),
        reason: 'content asking how big its world is means the panel',
      );
    });

    test('and an inset it reaches into is, in proportion', () {
      // `.full` is 812 and puts the panel's top edge at exactly 62 — the safe
      // boundary — so its top inset is still 0. One pixel further and it is 1.
      // Both rows matter: an implementation that forwarded the window's inset
      // whenever the panel was "tall enough" passes the `.medium` row above and
      // fails these two.
      expect(
        PanelMediaQuery.deriveFrom(
          _window(),
          panel: _sheetRect(kFullFrame),
          viewport: kIPhone17Pro.size,
        ).viewPadding.top,
        0,
      );
      expect(
        PanelMediaQuery.deriveFrom(
          _window(),
          // 40pt into the rubber band above `.full`, which a drag produces and
          // which is the only way this slice's panel gets here at all.
          panel: _sheetRect(kFullFrame + 40),
          viewport: kIPhone17Pro.size,
        ).viewPadding.top,
        closeTo(40, 1e-9),
      );
    });

    test('a keyboard is clamped to the panel it is covering', () {
      // 336pt of keyboard over a 214pt peek is 214pt of covered panel. The
      // clamp is not a nicety: the scaffold insets its body by this number, and
      // 336 inside a 214pt panel is a negative-height body and a framework
      // refusal three layers below whatever produced it.
      final derived = PanelMediaQuery.deriveFrom(
        _window(viewInsets: kKeyboard),
        panel: _sheetRect(kPeekFrame),
        viewport: kIPhone17Pro.size,
      );

      expect(derived.viewInsets.bottom, closeTo(kPeekFrame, 1e-9));
      expect(
        PanelMediaQuery.deriveFrom(
          _window(viewInsets: kKeyboard),
          panel: _sheetRect(kFullFrame),
          viewport: kIPhone17Pro.size,
        ).viewInsets.bottom,
        closeTo(336, 1e-9),
        reason: 'a panel taller than the keyboard sees all of it',
      );
    });

    test('and padding is what viewPadding has left after it', () {
      // KB6 from the content's end, and it is the pair the whole design turns
      // on: with the keyboard up `viewPadding.bottom` keeps its 34 and
      // `padding.bottom` collapses to 0. A `SafeArea` reads the second and a
      // detent reads neither.
      final derived = PanelMediaQuery.deriveFrom(
        _window(viewInsets: kKeyboard),
        panel: _sheetRect(kFullFrame),
        viewport: kIPhone17Pro.size,
      );

      expect(derived.viewPadding.bottom, 34);
      expect(derived.padding.bottom, 0);
    });

    test('a panel clear of its edge takes nothing from it', () {
      // A floating placement, or a dismissal once `EdgeOffset` moves: the panel
      // sits 100pt above the viewport's bottom, so the home indicator is not
      // under it and its content must not inset for one.
      final derived = PanelMediaQuery.deriveFrom(
        _window(),
        panel: Rect.fromLTRB(0, 400, 402, 774),
        viewport: kIPhone17Pro.size,
      );

      expect(derived.viewPadding.bottom, 0);
      expect(derived.viewPadding.top, 0);
    });

    test('and the same rule runs on the edges a drawer hangs off', () {
      // One formula, four edges — and only two of them are reachable through a
      // bottom sheet, so a projection that took the wrong edge of the pair on
      // the horizontal axis would be invisible until `PanelAnchor.leading`
      // ships. The derivation is pure, so it can be asked now: a 300pt drawer
      // against the reading-start edge of a 402pt viewport is 102pt clear of
      // the far one.
      final derived = PanelMediaQuery.deriveFrom(
        _window().copyWith(
          viewPadding: const EdgeInsets.fromLTRB(20, 62, 30, 34),
        ),
        panel: const Rect.fromLTRB(0, 0, 300, 874),
        viewport: kIPhone17Pro.size,
      );

      expect(derived.viewPadding.left, 20, reason: 'the panel is on that edge');
      expect(
        derived.viewPadding.right,
        0,
        reason: 'the 30pt inset at the far edge is 102pt from this panel',
      );
      // Both ends of the other axis, so that a swap of the two pairs — rather
      // than of the two edges within one — fails as well.
      expect(derived.viewPadding.top, 62);
      expect(derived.viewPadding.bottom, 34);
    });

    test('and padding is that subtraction on every edge, not just one', () {
      // `padding` is the pair a `SafeArea` reads, and a bottom sheet with a
      // keyboard exercises exactly one of its four edges — so `max` written as
      // `min`, or a difference written as a sum, is invisible on the other
      // three. The derivation is pure and per-edge, and it does not know which
      // of the four is a keyboard, so all four can be asked at once.
      final derived = PanelMediaQuery.deriveFrom(
        _window().copyWith(
          viewPadding: const EdgeInsets.fromLTRB(20, 62, 30, 34),
          viewInsets: const EdgeInsets.fromLTRB(10, 30, 14, 336),
        ),
        // 40pt into the rubber band above `.full`, so the panel's top edge is
        // 22 and both of the vertical insets reach it by a different amount.
        panel: _sheetRect(kFullFrame + 40),
        viewport: kIPhone17Pro.size,
      );

      expect(derived.viewPadding, const EdgeInsets.fromLTRB(20, 40, 30, 34));
      expect(derived.viewInsets, const EdgeInsets.fromLTRB(10, 8, 14, 336));
      expect(derived.padding, const EdgeInsets.fromLTRB(10, 32, 16, 0));
    });

    test('and an edge covered past its own safe area keeps nothing of it', () {
      // Saturation on an edge that is not the keyboard's. 25pt of inset over a
      // 20pt safe area is 0pt of padding — not −5, and not the 1 a lower bound
      // written one off would give.
      final derived = PanelMediaQuery.deriveFrom(
        _window().copyWith(
          viewPadding: const EdgeInsets.fromLTRB(20, 62, 30, 34),
          viewInsets: const EdgeInsets.fromLTRB(25, 0, 40, 0),
        ),
        panel: _sheetRect(kFullFrame),
        viewport: kIPhone17Pro.size,
      );

      expect(derived.padding.left, 0);
      expect(derived.padding.right, 0);
    });

    test('and a panel inset from its viewport measures from its own edges', () {
      // Every rect above starts at x = 0, where `system.left - panel.left` and
      // `system.left + panel.left` are the same number. A `CrossAxisFit.inset`
      // — iOS 26's side insets — is a panel whose left edge is not the
      // viewport's, and it is a geometry this slice cannot build and this
      // function can already be asked about.
      final derived = PanelMediaQuery.deriveFrom(
        _window().copyWith(
          viewPadding: const EdgeInsets.fromLTRB(20, 62, 30, 34),
        ),
        panel: const Rect.fromLTRB(50, 400, 352, 874),
        viewport: kIPhone17Pro.size,
      );

      expect(
        derived.viewPadding.left,
        0,
        reason: 'the 20pt inset is 50pt outside this panel',
      );
      expect(
        derived.viewPadding.right,
        0,
        reason: 'and the 30pt one is 50pt outside the other side of it',
      );
      expect(
        derived.viewPadding.bottom,
        34,
        reason: 'while the edge it is actually on still counts',
      );
    });

    test('and everything a panel has no opinion about is passed through', () {
      // The list this must *not* have: a `copyWith` that enumerated the fields
      // it keeps would be a list to keep in step with the framework, and the
      // failure would be a text scale that silently stopped applying inside
      // sheets.
      final window = _window().copyWith(
        textScaler: const TextScaler.linear(1.6),
        platformBrightness: Brightness.dark,
        disableAnimations: true,
      );
      final derived = PanelMediaQuery.deriveFrom(
        window,
        panel: _sheetRect(kMediumFrame),
        viewport: kIPhone17Pro.size,
      );

      expect(derived.textScaler, window.textScaler);
      expect(derived.platformBrightness, Brightness.dark);
      expect(derived.disableAnimations, isTrue);
      expect(derived.devicePixelRatio, kIPhone17Pro.devicePixelRatio);
    });
  });

  group('what the content actually reads', () {
    testWidgets('is the panel\'s insets and not the window\'s', (tester) async {
      late MediaQueryData seen;
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: Builder(
              builder: (context) {
                seen = MediaQuery.of(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(seen.viewPadding.top, 0);
      expect(seen.viewPadding.bottom, 34);
      expect(seen.size.height, closeTo(kMediumFrame, 1e-9));
    });

    testWidgets('so a SafeArea insets for what is under the panel only', (
      tester,
    ) async {
      // The whole point, expressed the way an app would meet it. Against the
      // window's padding this box would start 62pt lower than the sheet's own
      // top edge.
      await tester.pumpWidget(
        onIPhone17Pro(
          Panel(
            detents: kPeekSet,
            initialDetent: Detent.medium,
            child: const SafeArea(child: SizedBox.expand(key: Key('inset'))),
          ),
        ),
      );
      await tester.pump();

      final rect = tester.getRect(find.byKey(const Key('inset')));
      expect(rect.top, closeTo(874 - kMediumFrame, 1e-9));
      expect(rect.bottom, closeTo(874 - 34, 1e-9));
    });
  });

  group('and the detents do not move when the keyboard opens', () {
    testWidgets('byte for byte', (tester) async {
      // KB6 is proved by construction one layer down — `PanelBaseline` has no
      // `viewInsets` field — so what is left to break is a *widget* that shrinks
      // the box the panel is measured in. Wrapping a panel in
      // `Padding(bottom: MediaQuery.viewInsetsOf(context).bottom)` is exactly
      // what an app does today, and it moves every detent by 336pt.
      Widget build(EdgeInsets viewInsets) => onIPhone17Pro(
        viewInsets: viewInsets,
        Panel(
          detents: kPeekSet,
          initialDetent: Detent.medium,
          child: const SizedBox.expand(),
        ),
      );

      await tester.pumpWidget(build(EdgeInsets.zero));
      final before = extentIn(tester);
      final detentsBefore = modelIn(tester).detents;

      await tester.pumpWidget(build(kKeyboard));
      await tester.pump();

      expect(extentIn(tester), before);
      expect(modelIn(tester).detents, detentsBefore);
      expect(extentIn(tester), closeTo(kMediumFrame, 1e-9));
    });
  });
}
