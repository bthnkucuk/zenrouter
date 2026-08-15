/// The widget that installs [RenderPanelViewport], and the bridge from
/// `MediaQuery` to the layout it needs.
///
/// This is the only file in `render/` that may see a `BuildContext`, and it is
/// deliberately the thinnest thing that can: it reads four inherited values,
/// packs them into a [PanelMedia], and hands over a child. Every decision about
/// how big the panel is happens one layer down, in a render object, where making
/// it does not rebuild anything.
library;

// `widgets.dart` re-exports only a hand-picked slice of `foundation.dart` and
// the diagnostics builders are not in it, so the widget half names
// `rendering.dart` as well. It is a subset of what `widgets.dart` already
// brings, which is why this is an extra name rather than an extra power.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../geometry/anchor.dart';
import '../model/panel_model.dart';
import 'render_panel.dart';

/// The ambient half of a layout pass, read from [context].
///
/// **Reads four aspect-scoped accessors and never `MediaQuery.of`.** `of`
/// subscribes to every field of `MediaQueryData`, so a text-scale change, an
/// orientation flag or a `platformBrightness` flip would rebuild the panel's
/// element and call `updateRenderObject` — where the aspect accessors
/// (`viewPaddingOf`, `viewInsetsOf`, `devicePixelRatioOf`) each register a
/// dependency on one field and nothing else. The [PanelMedia] equality check in
/// the setter would catch the wasted call, but the wasted *build* is the one
/// that cannot be caught downstream, and DESIGN.md A7's first instrument counts
/// exactly those.
///
/// [MediaQuery.viewPaddingOf] and never `paddingOf`: `padding` collapses toward
/// zero as the keyboard rises while `viewPadding.bottom` keeps its 34pt, so a
/// panel reading `padding` loses 34pt off every detent the moment a field is
/// focused. `PanelBaseline` cannot refuse the wrong one — both are `EdgeInsets`
/// — so the refusal is here and the test that holds it is
/// `test/render/panel_viewport_test.dart`.
///
/// `Directionality.of` rather than a `MediaQuery` field, because the reading
/// direction is not a media property; it is what decides which edge a drawer
/// hangs off.
PanelMedia panelMediaOf(BuildContext context) => PanelMedia(
  viewPadding: MediaQuery.viewPaddingOf(context),
  viewInsets: MediaQuery.viewInsetsOf(context),
  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
  textDirection: Directionality.of(context),
);

/// Puts a panel in the tree: a box the size of its constraints, with [child]
/// laid out at whatever height [model] currently resolves to.
///
/// **Takes a model rather than building one.** A `PanelModel` outlives any one
/// build — it holds a running settle and a gesture's accumulated position — and
/// it is created by whoever owns the panel's lifetime: `Panel` for a non-modal
/// one, `PanelRoute` for a presented one, the paged host for its children.
/// Neither of those exists yet, and this widget works without them.
///
/// **Does not drive the model's ticker either.** `PanelModel` owns no
/// `TickerProvider` — that is the layering rule in DESIGN.md §6, and it is why
/// every test under `test/model/` runs without a binding — so something above
/// must watch [PanelModel.isTicking] and call [PanelModel.tick] each frame. That
/// something is `lib/src/widgets/panel.dart`, which is the next slice. Nothing
/// here animates on its own, and a test drives `tick` by hand.
///
/// What this widget *is* responsible for is the one thing a render object cannot
/// do: reading inherited state. That is [panelMediaOf], and it is the whole
/// bridge.
class PanelViewport extends SingleChildRenderObjectWidget {
  /// Installs a panel driven by [model].
  ///
  /// Every parameter but [model] defaults to this slice: the bottom anchor,
  /// attached to its edge, resizing rather than translating, measuring no
  /// content.
  const PanelViewport({
    super.key,
    required this.model,
    this.anchor = PanelAnchor.bottom,
    this.attachment = EdgeAttachment.edgeAttached,
    this.sizing = PanelSizing.resize,
    this.measuresContent = false,
    super.child,
  });

  /// The panel's two scalars and the activity moving them.
  final PanelModel model;

  /// Where the panel is attached, and therefore which way it grows.
  final PanelAnchor anchor;

  /// Whether the panel sits against its attachment edge or clear of it.
  final EdgeAttachment attachment;

  /// What a detent change moves.
  final PanelSizing sizing;

  /// Whether any detent needs the content measured. See
  /// [RenderPanelViewport.measuresContent] for why this is a parameter and what
  /// replaces it.
  final bool measuresContent;

  @override
  RenderPanelViewport createRenderObject(BuildContext context) =>
      RenderPanelViewport(
        model: model,
        media: panelMediaOf(context),
        anchor: anchor,
        attachment: attachment,
        sizing: sizing,
        measuresContent: measuresContent,
      );

  /// Updates the render object in place, re-reading the ambient media.
  ///
  /// Every assignment is guarded by a `==` on the far side, so a rebuild that
  /// changed nothing this panel reads marks nothing dirty. That matters more
  /// here than it looks: a keyboard animation rebuilds this element on every one
  /// of its frames, and each of those frames genuinely does move `viewInsets` —
  /// so the guard is what keeps *the other* rebuilds free.
  @override
  void updateRenderObject(
    BuildContext context,
    RenderPanelViewport renderObject,
  ) {
    renderObject
      ..model = model
      ..media = panelMediaOf(context)
      ..anchor = anchor
      ..attachment = attachment
      ..sizing = sizing
      ..measuresContent = measuresContent;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(EnumProperty<PanelAnchor>('anchor', anchor))
      ..add(EnumProperty<EdgeAttachment>('attachment', attachment))
      ..add(EnumProperty<PanelSizing>('sizing', sizing))
      ..add(
        FlagProperty(
          'measuresContent',
          value: measuresContent,
          ifTrue: 'measures content',
        ),
      );
  }
}
