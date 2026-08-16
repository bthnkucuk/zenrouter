/// What a panel publishes about itself, and the two lookups that read it.
///
/// **The panel publishes its position continuously, not its resting detent**,
/// and that is a requirement rather than a convenience — DESIGN.md A6.4 reaches
/// it from two directions at once. The sticky-bar row's `.conditional` variant
/// is *"a predicate over live metrics, re-evaluated whenever the metrics
/// change"*, and coverage row #21 (`offset_driven_animation`) is built on
/// nothing else. Publishing only the detent fails both, and it fails them
/// silently: a panel that notified twice a settle would look right in every
/// still frame and wrong in every moving one.
///
/// Continuous publication costs something, so this file spends the cost where
/// it is asked for and nowhere else. There are **two** inherited widgets under
/// [PanelScope] and therefore two lookups:
///
/// - [PanelScope.of] finds the [PanelController]. It depends on the controller's
///   *identity*, so a widget that only wants to call [PanelController.animateTo]
///   is not rebuilt by a panel that is moving.
/// - [PanelScope.metricsOf] finds the live [PanelMetrics]. It depends on the
///   notifier, so it rebuilds on every frame the panel moves — which is the
///   point, and is why it is a separate call rather than a field on the first
///   one.
///
/// One scope with both would make every consumer of the controller a consumer
/// of the position, and the sticky-bar row's own body would then rebuild sixty
/// times a second because something in it wanted a `settleTo`. This is
/// `MediaQuery.of` versus `MediaQuery.sizeOf`, for the same reason.
library;

// `widgets.dart` re-exports a hand-picked slice of `foundation.dart` and
// `ValueListenable` is not in it, so the controller's own interface has to be
// named from the wider library. It is a subset of what `widgets.dart` already
// brings, which is why this is an extra name rather than an extra power — the
// same reasoning `render/panel_viewport.dart` gives for naming `rendering.dart`
// beside `widgets.dart`.
import 'package:flutter/foundation.dart';
// The phase, and nothing else. `widgets.dart` does not re-export
// `scheduler.dart` — it re-exports `foundation.dart show Brightness, UniqueKey`
// and `rendering.dart show TextSelectionHandleType` and nothing wider — so the
// one enum that says whether a frame is currently being built has to be named.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../geometry/anchor.dart';
import '../geometry/detent.dart';
import '../geometry/detent_set.dart';
import '../geometry/layout.dart';
import '../geometry/units.dart';
import '../model/panel_model.dart';
import '../physics/motion.dart';

/// Everything a panel knows about where it currently is, as one value.
///
/// **A value type, and the equality is load-bearing in both directions.** It is
/// what lets a consumer hold last frame's metrics and compare, and it is what
/// keeps a `MediaQuery` derived from these from notifying its dependents on a
/// frame where nothing they read changed. What it deliberately does *not* do is
/// suppress the notification itself: [PanelController] forwards the model's
/// notifications verbatim, because the model already only notifies when
/// something moved, and a second "did it really move" test here would be a
/// second answer to a question that already has one.
///
/// **The two scalars are carried apart, and never multiplied.** [extent] is how
/// big the panel is and [edgeOffset] is how far it has come; DESIGN.md §2.1 is
/// the whole argument and [rect] is the one place they are combined, through
/// the one function that is allowed to combine them.
///
/// The derived scalars each name their divisor, because the divisor is the part
/// that gets guessed. [openProgress] normalises against the *travel*;
/// [presentationProgress] against the entering span, measured from the
/// placement's resting offset rather than from zero (A2). Anything else a
/// consumer wants is derivable from the raw fields, which is why all of them
/// are here rather than replaced by conveniences.
@immutable
final class PanelMetrics {
  /// Records where a panel is.
  ///
  /// Public so that a bottom-bar predicate, a derived `MediaQuery` or an
  /// animation can be tested against a state a live panel cannot reach yet — a
  /// non-zero [edgeOffset] is the obvious one, since this slice pins it at
  /// [EdgeOffset.zero] and dismissal is what moves it.
  const PanelMetrics({
    required this.extent,
    required this.edgeOffset,
    required this.restingOffset,
    required this.detents,
    required this.layout,
    required this.anchor,
  });

  /// How big the panel is: the frame span from the attachment edge to the
  /// leading edge.
  final Extent extent;

  /// How far the panel's attachment edge sits from the viewport's.
  final EdgeOffset edgeOffset;

  /// Where this panel's placement rests when it is fully present.
  ///
  /// [EdgeOffset.zero] for every edge-attached placement, and
  /// `(viewportSpan - extent) / 2` for a centred one. Carried rather than
  /// assumed because assuming zero is exactly A2's defect: a 300pt dialog fully
  /// present in an 874pt viewport would report itself 4% present.
  final EdgeOffset restingOffset;

  /// The heights the panel may currently rest at.
  final ResolvedDetents detents;

  /// The layout the panel was last measured in — the baseline detents resolve
  /// against, the keyboard inset, the pixel ratio and the reading direction.
  final PanelLayout layout;

  /// Where the panel is attached, and therefore which way it grows.
  final PanelAnchor anchor;

  /// The rectangle the panel occupies in its viewport.
  ///
  /// `PanelAnchor.rectOf`, which is the only function in the package that turns
  /// the two scalars into a rect. Derived on read rather than carried, so that
  /// this and the render object's own `panelRect` cannot become two answers:
  /// they are one function called twice with the same arguments.
  Rect get rect => anchor.rectOf(extent, edgeOffset, layout);

  /// The viewport the panel sits in, as a `Size`.
  ///
  /// Assembled from the baseline's span and cross measurements, which are
  /// stored by axis rather than by edge — so this is the one place the pair is
  /// put back into screen order, and it is an [Axis] switch rather than a
  /// direction one. `PanelAnchor` stays the only file that knows a direction.
  Size get viewportSize => switch (layout.baseline.spanAxis) {
    Axis.vertical => Size(
      layout.baseline.crossSpan,
      layout.baseline.viewportSpan.px,
    ),
    Axis.horizontal => Size(
      layout.baseline.viewportSpan.px,
      layout.baseline.crossSpan,
    ),
  };

  /// How much of the panel's attachment edge the system is currently covering,
  /// in logical pixels.
  ///
  /// The keyboard, for a bottom sheet. Projected onto the attachment edge
  /// through `PanelAnchor.attachedPadding`, which is a projection of an
  /// arbitrary `EdgeInsets` onto that edge and is named for its first caller
  /// rather than for what it does. Reaching into `layout.viewInsets` by edge
  /// here instead would put a screen direction in a second file, which is the
  /// one thing `PanelAnchor` exists to prevent.
  ///
  /// It is [Extent.zero] whenever nothing is covering the edge, which is the
  /// overwhelmingly common case, and it is what separates a bottom bar that
  /// rides the panel's edge from one that stays clear of the keyboard on a
  /// panel whose [edgeOffset] is pinned at zero.
  Extent get obstruction =>
      anchor.attachedPadding(layout.viewInsets, layout.textDirection);

  /// How present the panel is, in `[0, 1]` — the route animation's value.
  ///
  /// Derived from [edgeOffset] against [restingOffset], never driven, and so
  /// 1.0 at every detent. A barrier at `.medium` is at full opacity because of
  /// this getter, and DESIGN.md §5 rejects design B because its equivalent
  /// answers 0.56 there.
  double get presentationProgress =>
      edgeOffset.presentationProgress(extent, restingOffset: restingOffset);

  /// How far through its own travel the panel is, in `[0, 1]`.
  ///
  /// **The divisor is the travel — `detents.max - detents.min` — and that is a
  /// choice.** A panel with a 180pt peek and an 812pt full has its interesting
  /// range between those two, so 0 at the smallest stop and 1 at the largest is
  /// what an offset-driven animation wants. Normalising against the viewport or
  /// against `detents.max` instead would leave a peeking sheet at 0.26 and give
  /// every animation built on it a dead first quarter. Both raw ends are on
  /// [detents], so a consumer that wants a different divisor has one.
  ///
  /// **1.0 when the travel is zero.** A one-detent panel is standing on its
  /// only stop and is therefore as open as it goes; the division would be
  /// `0 / 0`, and a `NaN` here reaches a `Tween`, an `Opacity` and a `Transform`
  /// before anything notices. The one-detent set is not a degenerate case — it
  /// is what `Detent.full` alone means, and DESIGN.md A4 says a `.medium`-only
  /// set is legal too.
  double get openProgress {
    final travel = detents.travel.px;
    // Stated, not inherited. `0 / 0` is `NaN`, and `NaN.clamp(0.0, 1.0)`
    // already answers 1.0 — `num.clamp` compares with `compareTo`, which orders
    // NaN *above* the upper limit. That is the same quirk DESIGN.md A3 names as
    // the reason a NaN fraction is silently indistinguishable from `.full`, so
    // it is exactly the wrong thing to be relying on for an answer: the guard
    // is here to say the one-detent case has a defined value, rather than to
    // borrow one from an ordering that is a footnote in the SDK.
    if (travel == 0) return 1;
    return ((extent.px - detents.min.px) / travel).clamp(0.0, 1.0);
  }

  /// The resting height nearest where the panel is now.
  ///
  /// The answer to "which detent is this panel at", asked in the one way that
  /// is always answerable: a panel mid-drag is at no detent and has a nearest
  /// one. `ResolvedDetents.nearestTo` is the same function the snap uses, so
  /// this cannot disagree with where a release at zero velocity would land.
  Detent get nearestDetent => detents.nearestTo(extent);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PanelMetrics &&
          other.extent == extent &&
          other.edgeOffset == edgeOffset &&
          other.restingOffset == restingOffset &&
          other.detents == detents &&
          other.layout == layout &&
          other.anchor == anchor;

  @override
  int get hashCode =>
      Object.hash(extent, edgeOffset, restingOffset, detents, layout, anchor);

  @override
  String toString() =>
      'PanelMetrics(extent: ${extent.px}, edgeOffset: ${edgeOffset.px}, '
      'restingOffset: ${restingOffset.px}, anchor: ${anchor.name}, '
      '$detents, $layout)';
}

/// The app's handle on a panel: what it is doing now, and how to move it.
///
/// **A `ValueListenable<PanelMetrics?>`, and the null is the honest part.** A
/// controller an app constructed and has not yet handed to a `Panel` has no
/// panel to report on, exactly as a `ScrollController` with no attached position
/// has no `position`. `ScrollController` answers that by throwing from
/// `position` and publishing `hasClients`; this answers it with a null value,
/// because the type is the one `ValueListenableBuilder` and `AnimatedBuilder`
/// already know how to consume — and consuming it is what coverage row #21 asks
/// for.
///
/// Inside a panel there is no null: [PanelScope.metricsOf] resolves to
/// non-nullable metrics from the first build, because the model is constructed
/// before the content is built.
///
/// **Optional on a panel.** A panel with no controller builds one, so content
/// can always reach [PanelScope.of] and nothing has to be threaded through an
/// app to make a sheet work. A controller the app made is the app's to dispose;
/// one the panel made is the panel's. That is `ScrollController`'s division and
/// there is no reason to invent another.
class PanelController extends ChangeNotifier
    implements ValueListenable<PanelMetrics?> {
  /// Creates a detached controller.
  PanelController();

  /// Where the panel is, or null while this controller has no panel.
  ///
  /// Rebuilt once per notification and cached, rather than derived on every
  /// read. Two reads in one frame therefore give the identical object, which is
  /// what makes `==` between frames mean "the panel did not move" rather than
  /// "these two happen to be equal".
  @override
  PanelMetrics? get value => _value;
  PanelMetrics? _value;

  /// The panel this controller drives, or null while it has none.
  PanelModel? _model;

  /// The anchor the attached panel was installed with.
  ///
  /// Carried beside the model because a `PanelModel` does not know which way it
  /// grows — that is `PanelAnchor`'s job and the model is deliberately
  /// placement-blind — and [PanelMetrics] needs one to turn two scalars into a
  /// rect.
  PanelAnchor _anchor = PanelAnchor.bottom;

  /// Whether a panel is currently driving this controller.
  bool get isAttached => _model != null;

  /// Binds this controller to [model].
  ///
  /// Internal: the model is the package's machine and is not part of the export
  /// surface. `Panel` calls this once it has a model, and [detach] from
  /// `dispose`. A controller may drive exactly one panel at a time — two panels
  /// sharing one would give [animateTo] two panels to move and [value] two
  /// positions to report, and which one won would depend on which rebuilt last.
  @internal
  void attach(PanelModel model, {required PanelAnchor anchor}) {
    assert(
      _model == null,
      'This PanelController already drives a panel. Two panels sharing one '
      'would give animateTo two panels to move and value two positions to '
      'report, and which one won would depend on which rebuilt last. Give the '
      'second panel a controller of its own, or none at all — a panel with no '
      'controller makes one, and its content still reaches it through '
      'PanelScope.of.',
    );
    _model = model;
    _anchor = anchor;
    model.addListener(_panelChanged);
    // Read once here rather than left null until the panel first moves: the
    // model is constructed before the content is built, so there is a position
    // to publish from the first build, and content laid out against a null is
    // the blank first frame this package is written against.
    _panelChanged();
  }

  /// Unbinds this controller, leaving [value] null.
  ///
  /// Called by the panel that attached it, and not by the app. It does not
  /// dispose the model: a controller outliving its panel is ordinary — an app
  /// holds one in its own `State` — and a detached controller that had disposed
  /// somebody else's model would be a use-after-free the next time the panel
  /// was rebuilt.
  ///
  /// **Does not notify**, which is `ScrollController.detach`'s own choice and is
  /// made for the same reason. The only thing it could announce is "there is no
  /// panel any more", and the only listener that could hear it is one whose
  /// panel has just left — an app listener written as `controller.value!`, the
  /// shape [value]'s own doc invites, would dereference null from inside the
  /// frame its widget is being torn down in. A detached controller answers null
  /// on the next read, and [isAttached] is the question to ask.
  @internal
  void detach() {
    _model?.removeListener(_panelChanged);
    _model = null;
    _value = null;
  }

  /// Rebuilds [value] from the model and passes the notification on.
  ///
  /// The metrics are built **once per notification** rather than on every read,
  /// so two reads in one frame give the identical object — which is what makes
  /// `==` between frames mean "the panel did not move" rather than "these two
  /// happen to be equal".
  ///
  /// The model's notification is not filtered: it already only notifies when
  /// something moved, and a second "did it really move" test here would be a
  /// second answer to a question that already has one. It is only, sometimes,
  /// *delayed* — see [_announce].
  void _panelChanged() {
    final model = _model!;
    _value = PanelMetrics(
      extent: model.extent,
      edgeOffset: model.edgeOffset,
      restingOffset: model.restingOffset,
      detents: model.detents,
      layout: model.layout,
      anchor: _anchor,
    );
    _announce();
  }

  /// Notifies, at a moment when it is legal for a listener to answer.
  ///
  /// **A panel commits its layout from inside a layout pass**, and that is
  /// deliberate rather than incidental: `RenderPanelViewport.performLayout` lays
  /// the child out and then calls `PanelModel.applyLayout`, whose whole job is
  /// to commit and tell people. So a notification can arrive while the framework
  /// is building, laying out or painting a frame — and both of the things a
  /// listener naturally does in response are errors there. Marking a dependent
  /// dirty throws *"Build scheduled during frame"* from
  /// `WidgetsBinding._handleBuildScheduled`; marking a descendant of the panel
  /// as needing layout throws *"A RenderCustomMultiChildLayoutBox was mutated in
  /// RenderPanelViewport.performLayout"* from
  /// `RenderObject._debugCanPerformMutations`. Both were measured, not guessed:
  /// the first is what a `PanelMediaQuery` over a panel inside a `Padding` does
  /// on its first frame, and the second is what a content scaffold's layout
  /// delegate does on the same one.
  ///
  /// So a notification raised inside the frame's persistent-callback phase is
  /// held until the end of that frame, and every other one goes out at once.
  /// **The hot path is the immediate one**: every frame of a settle notifies
  /// from `PanelModel.tick`, which runs in the transient-callback phase, before
  /// the frame's work begins.
  ///
  /// **[value] is written either way, and that is the point of the split.** A
  /// reader that *asks* — `controller.value`, a layout delegate reading it while
  /// it runs — is exactly current; a reader that is *told* is one frame late on
  /// the passes where the layout itself moved the panel: a rotation, a keyboard,
  /// the first frame. That is the cost `panel_media_query.dart` already names as
  /// its own, arrived at from the other end.
  void _announce() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    // One deferral per frame. A pass that notified twice — a config adoption in
    // the build phase and a layout commit in the same frame — would otherwise
    // post two callbacks that answer the same question with the same value.
    if (_announcing) return;
    _announcing = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _announcing = false;
      // Detaching does not notify, so neither does an announcement that
      // outlived its panel: an app listener written as `controller.value!` —
      // the shape [value]'s doc invites — would dereference null in the frame
      // its own widget was torn down in.
      if (_disposed || _model == null) return;
      notifyListeners();
    });
  }

  /// Whether an announcement is already waiting for the end of this frame.
  bool _announcing = false;

  /// Whether [dispose] has run, so a deferred announcement knows not to.
  bool _disposed = false;

  /// The panel this controller drives, or a [FlutterError] naming what is
  /// missing.
  ///
  /// [method] is the call that wanted one, because "PanelController is not
  /// attached" three frames from the `animateTo` that said so is the failure
  /// mode this package is written against, one level up.
  PanelModel _panel(String method) {
    final model = _model;
    if (model != null) return model;
    throw FlutterError.fromParts(<DiagnosticsNode>[
      ErrorSummary(
        'PanelController.$method was called on a controller with no panel.',
      ),
      ErrorDescription(
        'A controller drives the Panel it was passed to, from the moment that '
        'panel is inserted into the tree until it leaves. This one has never '
        'been given to a panel, or the panel it was given to is gone.',
      ),
      ErrorHint(
        'Pass this controller to a Panel, and only move it once that panel has '
        'been built. PanelController.isAttached is the question to ask if the '
        'panel may legitimately not be there — a sheet that has already been '
        'dismissed, say.',
      ),
    ]);
  }

  /// Animates the panel to [detent] from rest.
  ///
  /// The programmatic move. [motion] overrides the panel's own spring for this
  /// one animation, which is how `recipes/programmatic_control_recipe` gets a
  /// bouncy open without reshaping every settle after it.
  ///
  /// Throws when this controller is attached to nothing, naming the panel that
  /// is missing: an `animateTo` that silently did nothing is the failure mode
  /// this whole package is written against, one level up.
  void animateTo(Detent detent, {PanelMotion? motion}) =>
      _panel('animateTo').animateTo(detent, motion: motion);

  /// Settles the panel at [detent], continuing whatever it is already doing.
  ///
  /// The difference from [animateTo] is the seed, and it is the whole of the
  /// difference: this carries the current velocity, so a settle installed over
  /// a running one picks the motion up instead of restarting it. An app that
  /// re-targets a panel from a gesture callback wants this one.
  void settleTo(Detent detent, {Duration? within}) =>
      _panel('settleTo').settleTo(detent, within: within);

  /// Records the disposal, so a deferred announcement knows not to arrive.
  ///
  /// **It deliberately does not [detach].** A controller disposed while its
  /// panel is still on screen is an app bug, and the loudest, most accurate
  /// report of it is `ChangeNotifier`'s own *"A PanelController was used after
  /// being disposed"*, raised from the first frame the panel moves. Detaching
  /// instead would swallow that and replace it, some number of frames later,
  /// with `PanelScope.metricsOf was called outside a Panel` — thrown from inside
  /// a panel, which is the least true sentence available.
  ///
  /// Nothing leaks by declining: a panel detaches its controller in its own
  /// `dispose`, before disposing the model that holds the listener.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Publishes a panel's controller and its live position to its content.
///
/// Installed by `Panel` around everything below it, so content reaches the
/// panel with no wiring — the same claim the scroll layer makes about a bare
/// `ListView`, applied to the panel's state. There is nothing for an app to
/// provide and nothing to configure.
///
/// **Two inherited widgets, one public name.** One carries the controller, the
/// other is an `InheritedNotifier` over the same controller and carries the
/// position. [of] depends on the first and [metricsOf] on the second, so a
/// widget pays for the position only if it asked for the position. The library
/// doc at the top of this file has the argument.
class PanelScope extends StatelessWidget {
  /// Publishes [controller] over [child].
  const PanelScope({super.key, required this.controller, required this.child});

  /// The panel's handle, and the notifier the metrics half listens to.
  final PanelController controller;

  /// The panel's content.
  final Widget child;

  /// The nearest enclosing panel's controller, without depending on its
  /// position.
  ///
  /// Throws outside a panel, naming `Panel`, because the alternative is a null
  /// dereference three widgets away from the mistake. [maybeOf] is for content
  /// that legitimately runs in both places — the same shape `Scaffold.of` and
  /// `Scaffold.maybeOf` have.
  static PanelController of(BuildContext context) =>
      maybeOf(context) ?? _notInAPanel('of', 'controller');

  /// [of], or null outside a panel.
  static PanelController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_PanelControllerScope>()
      ?.controller;

  /// The nearest enclosing panel's live position, rebuilding the caller
  /// whenever it changes.
  ///
  /// **This is the expensive lookup and it is meant to be.** A dependent
  /// rebuilds on every frame the panel moves, which is what a conditional
  /// bottom bar and every offset-driven animation need. Call it from the
  /// smallest widget that can answer the question, never from a build that also
  /// produces the content.
  ///
  /// Non-nullable: inside a panel there is always a position, from the first
  /// build. Throws outside one, for [of]'s reason.
  static PanelMetrics metricsOf(BuildContext context) =>
      maybeMetricsOf(context) ?? _notInAPanel('metricsOf', 'position');

  /// [metricsOf], or null outside a panel.
  static PanelMetrics? maybeMetricsOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_PanelMetricsScope>()
      ?.notifier
      ?.value;

  /// The refusal both lookups share, naming the widget that is missing.
  ///
  /// A `FlutterError` and not a null return, because the alternative is a null
  /// dereference three widgets away from the mistake — and the mistake is
  /// almost always the same one: content written for a panel is being reused
  /// somewhere that has none. [maybeOf] and [maybeMetricsOf] are for content
  /// that legitimately runs in both places.
  static Never _notInAPanel(String method, String what) {
    throw FlutterError.fromParts(<DiagnosticsNode>[
      ErrorSummary('PanelScope.$method was called outside a Panel.'),
      ErrorDescription(
        'A panel publishes its $what to its own content. This context has no '
        'Panel above it, so there is no $what to report.',
      ),
      ErrorHint(
        'Call this from inside a Panel\'s child. If the same widget is used '
        'both inside a panel and outside one, PanelScope.maybeOf and '
        'PanelScope.maybeMetricsOf answer null rather than throwing.',
      ),
    ]);
  }

  /// Nests the two halves. Written rather than deferred: the order carries no
  /// decision — an inherited lookup finds an ancestor at any depth — and there
  /// is nothing here but the structure the library doc already describes.
  @override
  Widget build(BuildContext context) => _PanelControllerScope(
    controller: controller,
    child: _PanelMetricsScope(notifier: controller, child: child),
  );
}

/// The controller half of [PanelScope].
///
/// Private, and looked up by exact type from [PanelScope.of], which is in the
/// same library. Separate from the metrics half only so that
/// `dependOnInheritedWidgetOfExactType` can tell the two dependencies apart.
class _PanelControllerScope extends InheritedWidget {
  const _PanelControllerScope({required this.controller, required super.child});

  final PanelController controller;

  /// Identity, and nothing else. A panel's controller is created once and lives
  /// as long as the panel, so this is false on every rebuild but the one where
  /// an app swapped the controller out — which is the only event a consumer of
  /// [PanelScope.of] has any reason to hear about.
  @override
  bool updateShouldNotify(_PanelControllerScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// The metrics half of [PanelScope] — an `InheritedNotifier` over the same
/// controller.
///
/// `InheritedNotifier` rebuilds every dependent on every notification without
/// consulting the value, which is correct here and is why [PanelMetrics]'
/// equality is not asked to suppress anything: the model already notifies only
/// when it moved.
class _PanelMetricsScope extends InheritedNotifier<PanelController> {
  const _PanelMetricsScope({
    required PanelController super.notifier,
    required super.child,
  });
}
