/// The `MediaQuery` a panel's content can trust.
///
/// **DESIGN.md A6.6 is a requirement about this file.** `smooth_sheets` hands
/// the arithmetic to the app, at the call site
/// (`example/lib/tutorial/textfield_with_multiple_stops.dart`):
///
/// ```dart
/// padding: EdgeInsets.only(
///   // Pad the content to avoid the software keyboard.
///   bottom: MediaQuery.viewInsetsOf(context).bottom,
/// ),
/// ```
///
/// That is the app doing the package's arithmetic, and A6.6 rules that *"a port
/// that reproduces the manual padding has failed the row, however well it
/// renders"*. Worse, the number is wrong as often as it is right: the screen's
/// `viewInsets` measures the keyboard against the *screen*, and the moment the
/// panel is not full height the content is not on the screen's edge.
///
/// So the panel re-measures every inset against **its own rect** and publishes
/// the result. One formula does all four edges and every anchor:
///
/// > an inset is what the system covers, less how far the panel already sits
/// > from that edge, saturated at zero.
///
/// A `.medium` sheet on an iPhone 17 Pro is 469.68pt tall in an 874pt viewport,
/// so its top edge is 404.32pt below the screen's — well clear of the 62pt
/// status bar — and its content's `viewPadding.top` is 0, not 62. Its bottom
/// edge is the screen's, so `viewPadding.bottom` stays 34. A `SafeArea` inside
/// the panel therefore insets for the home indicator and not for a notch that
/// is nowhere near it, and it does so with no wiring.
///
/// **This file is `widgets/panel_media_query.dart` and DESIGN.md §6 files it
/// under `render/`.** It moved because it needs the panel's live position,
/// which is published by `PanelScope` — a widget — and because `render/` may
/// not reach a `BuildContext` for the render object's sake. Nothing else about
/// it changed: it is still the one place the three insets are re-derived, and
/// the derivation itself ([PanelMediaQuery.deriveFrom]) is a pure function of a
/// rect so that it can be tested at panel geometries a live panel in this slice
/// cannot reach.
///
/// The origin is `smooth_sheets`' `SheetMediaQuery` (MIT), which the research
/// rates as covering this; the formula is ours, because our panel resizes where
/// theirs slides and the quantity to subtract is therefore different.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'scope.dart';

/// Re-derives the ambient insets against the panel's own rect and publishes
/// them over [child].
///
/// **One widget rebuild per frame the panel moves, and no subtree rebuild.**
/// This depends on `PanelScope.metricsOf`, so it rebuilds whenever the panel
/// does; [child] is the identical widget instance each time, so the framework's
/// own `Element.updateChild` short-circuits and nothing below is rebuilt. What
/// *does* rebuild is whatever called `MediaQuery.of` or one of its aspect
/// accessors, and only when the value it read actually changed — which is
/// `MediaQuery`'s own `updateShouldNotify` doing the work rather than a second
/// guard here.
///
/// That is the whole reason the derivation is not done in the render object,
/// where the rect is already known and exact. Publishing an inherited value
/// from a layout pass means rebuilding from a layout pass, which is what
/// `LayoutBuilder` does and what costs the relayout-boundary claim the render
/// layer is built on. The cost of doing it here instead is that the data is
/// derived from the extent the *upcoming* layout will use rather than from the
/// one it used: identical on every frame of a motion, since the model is
/// advanced before the build, and one frame stale on a pass where the layout
/// itself corrects the extent — a rotation, or the first frame.
class PanelMediaQuery extends StatelessWidget {
  /// Publishes the panel's own insets over [child].
  const PanelMediaQuery({super.key, required this.child});

  /// The panel's content.
  final Widget child;

  /// [ambient], re-measured against a panel occupying [panel] in a viewport of
  /// [viewport].
  ///
  /// **Static and pure**, because the interesting geometries are the ones a
  /// panel in this slice cannot reach: a rect above the largest detent (the
  /// rubber band), a rect narrower than its viewport (a future `CrossAxisFit`),
  /// a rect clear of its attachment edge (a floating placement, or a dismissal
  /// once `EdgeOffset` moves). A derivation that could only be exercised through
  /// a live panel would be tested at one rect and shipped for five.
  ///
  /// Every field it touches, and why:
  ///
  /// - **`size`** becomes `panel.size`. Content asking how big its world is
  ///   should be told about the panel, not about the window — a
  ///   `MediaQuery.sizeOf(context).height * 0.5` inside a peeking sheet is
  ///   otherwise four times the sheet. It is also the one field that moves on
  ///   *every* frame of a motion, so anything inside a panel that reads
  ///   `MediaQuery.sizeOf` rebuilds while the panel is moving. That is correct
  ///   — the answer really did change — and it is the reason
  ///   `PanelContentScaffold` reads the panel's position at layout instead of
  ///   asking for it in a build.
  /// - **`viewPadding`** is the system's, less the gap between the panel's edge
  ///   and the viewport's on that side, saturated at zero. This is the inset
  ///   that keeps its 34pt with the keyboard up, and it stays that way here.
  /// - **`viewInsets`** by the same rule, so a keyboard 336pt tall reaches a
  ///   214pt peek as 214 and not as 336. Clamping is not a nicety: the scaffold
  ///   insets its body by this number, and 336 inside a 214pt panel is a
  ///   negative-height body and a framework refusal three layers down.
  /// - **`padding`** is `viewPadding` less `viewInsets` per edge, saturated —
  ///   the framework's own relationship between the two, applied to the derived
  ///   pair rather than inherited from the ambient one. This is the pair KB6 is
  ///   about, from the content's end: `viewPadding.bottom` stays 34 with the
  ///   keyboard up and `padding.bottom` collapses to 0, and a `SafeArea` reads
  ///   the second.
  ///
  /// Everything else — the pixel ratio, the text scaler, the platform
  /// brightness, the accessibility flags — is passed through untouched. A panel
  /// has no opinion about them, and a `copyWith` that listed them would be a
  /// list to keep in step with the framework.
  static MediaQueryData deriveFrom(
    MediaQueryData ambient, {
    required Rect panel,
    required Size viewport,
  }) {
    // The one formula, per edge: what the system covers, less how far the panel
    // already sits from that edge, saturated at zero — and then held to the
    // panel's own span, because an inset larger than the box it describes is a
    // negative-height body three layers below whoever asked for it.
    EdgeInsets against(EdgeInsets system) => EdgeInsets.fromLTRB(
      _reach(system.left - panel.left, panel.width),
      _reach(system.top - panel.top, panel.height),
      _reach(system.right - (viewport.width - panel.right), panel.width),
      _reach(system.bottom - (viewport.height - panel.bottom), panel.height),
    );

    final viewPadding = against(ambient.viewPadding);
    final viewInsets = against(ambient.viewInsets);

    return ambient.copyWith(
      size: panel.size,
      viewPadding: viewPadding,
      viewInsets: viewInsets,
      // The framework's own relationship between the two, applied to the
      // derived pair rather than inherited from the ambient one. It is the pair
      // KB6 is about, read from the content's end: with the keyboard up
      // `viewPadding.bottom` keeps its 34 and `padding.bottom` collapses to 0,
      // and a `SafeArea` reads the second.
      padding: EdgeInsets.fromLTRB(
        math.max(0, viewPadding.left - viewInsets.left),
        math.max(0, viewPadding.top - viewInsets.top),
        math.max(0, viewPadding.right - viewInsets.right),
        math.max(0, viewPadding.bottom - viewInsets.bottom),
      ),
    );
  }

  /// [overlap] confined to `[0, span]` — how much of one edge of the panel an
  /// inset actually covers.
  static double _reach(double overlap, double span) =>
      overlap.clamp(0.0, math.max(0.0, span));

  @override
  Widget build(BuildContext context) {
    final metrics = PanelScope.metricsOf(context);
    return MediaQuery(
      data: deriveFrom(
        MediaQuery.of(context),
        panel: metrics.rect,
        viewport: metrics.viewportSize,
      ),
      child: child,
    );
  }
}
