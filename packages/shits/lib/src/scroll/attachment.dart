/// The wiring: three named arguments that make a bare `ListView` hand off with
/// nothing asked of the app.
///
/// This is the whole of the "no opt-in" claim as code. `capture_test.dart` is the
/// measurement behind it and is committed before anything here exists, because
/// the claim is about the *framework's* behaviour rather than about ours: a
/// `ListView`, a `ListView.builder` and a `CustomScrollView` all inherit an
/// ambient `PrimaryScrollController` on every platform — but only because the
/// controller is published with `automaticallyInheritForPlatforms:
/// TargetPlatform.values.toSet()`.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../model/activity.dart';
import 'behavior.dart';
import 'link.dart';
import 'position.dart';

/// Publishes the panel's controller and its behaviour over [child].
///
/// The tree it builds, and why each line is load-bearing:
///
/// ```dart
/// PrimaryScrollController(
///   controller: _controller,
///   scrollDirection: link.anchor.spanAxis,
///   automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
///   child: ScrollConfiguration(
///     behavior: PanelScrollBehavior(
///       inner: ScrollConfiguration.of(context),
///       link: link,
///     ),
///     child: child,
///   ),
/// )
/// ```
///
/// - **`automaticallyInheritForPlatforms`** defaults to `{android, iOS, fuchsia}`
///   (`primary_scroll_controller.dart:24-28`). `smooth_sheets-1.0.3` uses the
///   bare constructor (`lib/src/scrollable.dart:828-831`), so its scroll↔sheet
///   handoff does **nothing** on macOS, Windows, Linux or desktop web for a
///   controller-less `ListView`. This one argument is the difference, and
///   `capture_test.dart` fails on three desktop rows if it is removed as
///   redundant.
/// - **`scrollDirection: link.anchor.spanAxis`** is what makes a drawer capture
///   horizontal scrollables and — correctly — leaves a horizontal `PageView`
///   inside a bottom sheet alone. `shouldInherit` compares it against the
///   scrollable's own axis (`primary_scroll_controller.dart:135`), so the
///   carousel-in-a-sheet case is the framework's answer rather than ours.
/// - **The published widget is the framework's `PrimaryScrollController`**, never
///   a subclass, because `shouldInherit` looks it up with
///   `findAncestorWidgetOfExactType` and a subclass would be invisible to it.
/// - **`ScrollConfiguration.of(context)` is read and wrapped**, not replaced, so
///   the app's own scrollbar, drag devices and platform survive inside the panel.
///
/// **Stateful because the controller is.** A `ScrollController` has to be
/// created once and disposed once; a `StatelessWidget` that built one in `build`
/// would leak one per frame and detach every position on every rebuild. The
/// [PanelScrollLink] is *not* created here — it belongs to whoever owns the
/// `PanelModel`, since the two have the same lifetime and the link outlives this
/// widget's element.
///
/// **The hijack, documented rather than hidden.** Everything inside the panel
/// that reaches for the ambient primary controller now gets ours: `Scaffold`'s
/// status-bar-tap scroll-to-top, `ScrollAction`'s PageUp/PageDown,
/// `NestedScrollView`'s outer controller. And `ScrollController.position` throws
/// when two lists are attached, which a `TabBarView` of lists produces
/// immediately. DESIGN.md open question 6 is exactly this and is unresolved; the
/// test that settles it is a full `Scaffold` with an `AppBar` inside a panel, and
/// it is not in this slice.
class PanelScrollAttachment extends StatefulWidget {
  /// Publishes [link]'s controller over [child].
  const PanelScrollAttachment({
    super.key,
    required this.link,
    required this.child,
  });

  /// The arbiter every captured position will hold.
  final PanelScrollLink link;

  /// The panel's content.
  final Widget child;

  @override
  State<PanelScrollAttachment> createState() => _PanelScrollAttachmentState();
}

class _PanelScrollAttachmentState extends State<PanelScrollAttachment>
    with SingleTickerProviderStateMixin {
  /// The controller published to the subtree.
  ///
  /// Recreated when [PanelScrollAttachment.link] is swapped, because a
  /// controller's positions hold the link they were created with and there is no
  /// way to repoint them that is not `absorb`.
  late PanelScrollController controller;

  /// The clock a self-driven panel motion runs on.
  ///
  /// **DESIGN.md gives this to `lib/src/widgets/panel.dart`, which does not
  /// exist yet, and something has to hold it.** `PanelModel` owns no
  /// `TickerProvider` — that is the layering rule in §6, and it is what keeps
  /// every test under `test/model/` device-free — so a settle that nobody ticks
  /// is a panel that stops mid-travel. The one path in this slice that produces
  /// one is the release build's degraded drag: an escaped list ends its gesture
  /// and the panel is handed to a settle with no fused fling anywhere near it.
  ///
  /// **It ticks self-driven activities only, and that is what keeps "one ticker
  /// per fling" true.** A `ScrollDrivenActivity` is by definition being driven
  /// by `FusedBallisticActivity`, which advances the model's clock itself; if
  /// this ticked those too, a fused fling would run two tickers for one
  /// simulation and falsification criterion 4 would be false. The gate is the
  /// branch of the hierarchy, not a flag, so a leaf added later cannot land on
  /// the wrong side of it by accident.
  /// Created in [initState] rather than lazily: a `late final` initialiser that
  /// nothing had reached would be run by [dispose] itself, and building a
  /// `Ticker` from a deactivated element throws while the tree is being
  /// finalised — an error that names the ticker and not the lazy field.
  late final Ticker _ticker;

  /// The previous frame's total, so the model is advanced by a frame delta.
  Duration _elapsed = Duration.zero;

  /// Creates the controller and starts watching the model. Written rather than
  /// deferred: there is no decision in it, only an order, and the order is
  /// forced.
  @override
  void initState() {
    super.initState();
    controller = PanelScrollController(
      link: widget.link,
      debugLabel: 'PanelScrollAttachment',
    );
    _ticker = createTicker(_tick);
    widget.link.model.addListener(_activityChanged);
  }

  /// Whether the panel is moving itself and so needs frames from here.
  bool get _needsFrames {
    final model = widget.link.model;
    return model.activity is SelfDrivenActivity && model.isTicking;
  }

  /// Starts or stops the ticker to match [_needsFrames].
  ///
  /// Called from the model's own notification, which is the only thing that can
  /// change the answer — an activity is installed, or a tick finished one.
  void _activityChanged() {
    if (_needsFrames == _ticker.isTicking) return;
    if (_ticker.isTicking) {
      _ticker.stop();
    } else {
      _elapsed = Duration.zero;
      _ticker.start();
    }
  }

  /// One frame of a self-driven motion.
  ///
  /// The stop is re-checked after the tick rather than before it, because the
  /// tick is what parks the panel: an activity that finishes writes its last
  /// extent and installs an idle one, and asking first would spend a frame
  /// discovering that.
  void _tick(Duration elapsed) {
    final delta = elapsed - _elapsed;
    _elapsed = elapsed;
    widget.link.model.tick(delta);
    if (!_needsFrames) _ticker.stop();
  }

  /// Replaces the controller when the link is swapped, old one disposed last.
  ///
  /// Last, because disposing a controller detaches every position on it, and a
  /// position detaching wants a live link to unregister from.
  @override
  void didUpdateWidget(PanelScrollAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.link, oldWidget.link)) return;
    oldWidget.link.model.removeListener(_activityChanged);
    widget.link.model.addListener(_activityChanged);
    final previous = controller;
    controller = PanelScrollController(
      link: widget.link,
      debugLabel: 'PanelScrollAttachment',
    );
    previous.dispose();
    // The new link's panel may be mid-settle while the old one's was parked, and
    // nothing else will ask until it next notifies.
    _activityChanged();
  }

  @override
  void dispose() {
    _ticker.dispose();
    widget.link.model.removeListener(_activityChanged);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PrimaryScrollController(
    controller: controller,
    // What makes a drawer capture horizontal scrollables and — correctly —
    // leaves a horizontal `PageView` inside a bottom sheet unarbitrated.
    // `shouldInherit` compares this against the scrollable's own axis
    // (`primary_scroll_controller.dart:135`), so the carousel-in-a-sheet case is
    // the framework's answer rather than ours.
    scrollDirection: widget.link.anchor.spanAxis,
    // The one argument the whole no-opt-in claim rests on. The default is
    // `{android, iOS, fuchsia}`, so without this a bare `ListView` on macOS,
    // Windows or Linux silently does not inherit and the handoff does nothing on
    // every desktop — which is what `smooth_sheets` ships.
    //
    // `attachment_test.dart`'s platform sweep is what fails if it is narrowed:
    // it drags a bare `ListView` inside a real panel on every `TargetPlatform`
    // and checks the list is one of ours and that the drag moved the panel.
    // **Not `capture_test.dart`** — that file imports nothing from this package
    // and builds its own `PrimaryScrollController`, so it measures the
    // framework's premise and cannot fail on anything written here.
    automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
    child: ScrollConfiguration(
      // Read and wrapped, never replaced: a `ScrollBehavior` decides the
      // platform, the drag devices, the overscroll indicator, the scrollbar and
      // the keyboard-dismiss behaviour, and a panel has an opinion about exactly
      // one of them.
      behavior: PanelScrollBehavior(
        inner: ScrollConfiguration.of(context),
        link: widget.link,
      ),
      child: widget.child,
    ),
  );
}
