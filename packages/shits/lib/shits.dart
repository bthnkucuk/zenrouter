/// A panel that enters from an edge or the centre, resizes to its detents, and
/// hands scrolling off to dragging without being asked to.
///
/// ```dart
/// Panel(
///   detents: const DetentSet([
///     Detent.height(DetentValue(180)),
///     Detent.medium,
///     Detent.full,
///   ]),
///   initialDetent: Detent.medium,
///   child: ListView.builder(
///     itemCount: 200,
///     itemBuilder: (context, i) => ListTile(title: Text('Place $i')),
///   ),
/// )
/// ```
///
/// That is the whole of the setup. The `ListView` has no controller, no wrapper
/// and no configuration object, and dragging it grows the panel to its next
/// detent and then scrolls, in one gesture, on every platform.
///
/// ---
///
/// ## What this door opens onto, and what it does not
///
/// This file is the package's only export surface (DESIGN.md §6), so it is a
/// decision rather than a list, and the decision is: **the vocabulary an author
/// writes down is public; the machine that reads it is not.**
///
/// Public, in three groups:
///
/// - **The widgets an app puts in a tree** — [Panel], [PanelContentScaffold],
///   [PanelMediaQuery] — and the state they publish, [PanelController],
///   [PanelMetrics] and [PanelScope]. An app reaches the panel from inside its
///   own content through the scope, so nothing has to be threaded down.
/// - **The vocabulary** — [Detent] and its kinds, [DetentSet],
///   [ResolvedDetents], the units ([Extent], [DetentValue], [Fraction],
///   [EdgeOffset] and the rest), [PanelAnchor], [PanelBaseline], [PanelLayout].
///   These are what an author writes and what a predicate reads back, so all of
///   them are here even though an app will only ever construct three.
/// - **The policies** — [BottomBarVisibility], [PanelScrollPolicy],
///   [PanelRefreshPolicy], [MomentumCarry], [SnapPolicy], [PanelSizing],
///   [PanelMotion], [EdgeAttachment] — with their named defaults. DESIGN.md A5
///   is why each unsettled choice is a named type instead of a constant, and a
///   named type that could not be named from outside would be a constant with
///   extra steps.
///
/// Deliberately **not** public, and each for a reason rather than by omission:
///
/// - **`PanelModel`, `PanelConfig`, `PanelActivity` and `LayoutCorrection`** —
///   the machine. The model is a mutable object with a commit protocol whose
///   two halves must be called in one order from inside a layout pass; handing
///   it out would make every invariant in `model/` a documentation request. An
///   app moves a panel through [PanelController], and a *host* — `PanelRoute`,
///   the paged host — is inside this package and reaches the model directly.
///   The cost, named: nobody outside can write a second kind of host until one
///   of those lands. That is the right trade at 0.1.0 and it is reversible;
///   the other direction is not.
/// - **`PanelViewport`, `RenderPanelViewport`, `PanelMedia`** — the render
///   layer. `PanelViewport` takes a `PanelModel`, so exporting it exports the
///   model.
/// - **`PanelScrollLink`, `PanelScrollPosition`, `PanelScrollBehavior`,
///   `PanelScrollPhysics`, `PanelScrollAttachment`, `FusedAxis`,
///   `FusedSimulation`, `RubberBand`** — the arbiter and the physics. There is
///   nothing to configure on them that is not already a policy above, and every
///   one of them is reachable only through a panel that installed it.
/// - **[PanelScrollController] is the one exception**, and it is not an
///   oversight: it is half of what the escape error tells an author to reach
///   for. A list that genuinely needs a controller of its own — to jump to an
///   index, to read an offset — keeps its place in the handoff by being handed
///   one of these instead of a plain `ScrollController`. That is a two-word fix,
///   and a fix a message names has to be a fix a caller can write.
///
/// ---
///
/// ## One honest limit
///
/// The units in this package are **extension types**, and extension types
/// erase. They make the confusions that have actually shipped in this problem
/// space into compile errors — a fraction of the content read as a fraction of
/// the container, a detent resolved against the raw viewport instead of the
/// safe span, a scroll velocity handed to a panel that measures growth the
/// other way, a fused coordinate written to `setPixels` — and they do it with
/// no runtime cost and no runtime check. What they do not do is survive
/// `==` against their own representation: `someExtent == 0.56` compiles and is
/// true, and `identical` sees straight through them. The claim is that eleven
/// specific, cited bug classes move from runtime to compile time, and nothing
/// beyond that.
library;

// ---------------------------------------------------------------------------
// The widgets, and the state they publish.
// ---------------------------------------------------------------------------

export 'src/widgets/content_scaffold.dart'
    show
        AlwaysBottomBar,
        BottomBarPredicate,
        BottomBarVisibility,
        ConditionalBottomBar,
        NaturalBottomBar,
        PanelContentScaffold;
export 'src/widgets/panel.dart' show Panel, kPanelBandResistance;
export 'src/widgets/panel_media_query.dart' show PanelMediaQuery;
export 'src/widgets/scope.dart' show PanelController, PanelMetrics, PanelScope;

// ---------------------------------------------------------------------------
// The vocabulary: what an author writes down, and what a predicate reads back.
// ---------------------------------------------------------------------------

export 'src/geometry/anchor.dart' show EdgeAttachment, PanelAnchor;
export 'src/geometry/baseline.dart' show PanelBaseline, kCompactHeightThreshold;
export 'src/geometry/detent.dart'
    show AbsoluteDetent, Detent, FractionDetent, FullDetent, MediumDetent;
export 'src/geometry/detent_set.dart' show DetentSet, ResolvedDetents;
export 'src/geometry/layout.dart' show PanelLayout;
export 'src/geometry/units.dart'
    show
        Baseline,
        DetentValue,
        EdgeOffset,
        Extent,
        ExtentVelocity,
        Fraction,
        ScrollVelocity,
        ViewportExtent;

// ---------------------------------------------------------------------------
// The policies, and the constants their defaults are named by. A5: a policy
// nobody can name from outside is a hardcoded choice with extra steps.
// ---------------------------------------------------------------------------

export 'src/model/panel_model.dart' show kResnapWindow;
export 'src/physics/momentum.dart' show MomentumCarry;
export 'src/physics/motion.dart'
    show PanelMotion, kPanelInteractiveDuration, kPanelMotionDuration;
export 'src/physics/snap.dart' show SnapPolicy;
export 'src/render/render_panel.dart' show PanelSizing;
export 'src/scroll/policy.dart' show PanelRefreshPolicy, PanelScrollPolicy;

// ---------------------------------------------------------------------------
// The one piece of the arbiter an author is ever told to name.
// ---------------------------------------------------------------------------

export 'src/scroll/position.dart' show PanelScrollController;
