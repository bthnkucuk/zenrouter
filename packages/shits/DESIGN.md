# shits — design

Merged from three independent designs (iOS-fidelity, Flutter-idiom, configurability lenses)
and a synthesis pass. This document is the contract implementation works from. Where it and
the code disagree, the code is wrong until this is amended.

**Standing decision that post-dates the design brief: the package has no third-party
dependencies.** `motor` was dropped — see `pubspec.yaml` for the reasoning. Anywhere below
that names `motor` or `CupertinoMotion`, read: our own motion value type over
(duration, bounce), built on `SpringDescription.withDurationAndBounce`, with the four
constants pinned by us (`.smooth` 500/0, `.snappy` 500/0.15, `.bouncy` 500/0.3,
`.interactive` 150/0.14) and attributed to motor (MIT) in a comment.

---

## Spine

Design A is the spine. The task asks for a geometry model and a type vocabulary, and A is the only one that gets both load-bearing seams structurally right. Its two scalars — `Extent` (frame span, resized) and `EdgeOffset` (pixel displacement from the attachment edge, translated) — separate "how big" from "how present" in pixels, so dismissal tracks the finger 1:1 with no conversion factor. B has one scalar, so its route seam starts a dismissal from `.medium` at 0.56 presence; C splits correctly but into a 0..1 `Presence`, needing a divisor C itself ranks as its third risk. And A's `PanelBaseline` is constructed from size and viewPadding only, so `viewInsets` is not merely excluded from detent arithmetic — it is unreachable from it. That makes KB6, the research's single most expensive arithmetic rule, a fact about the type rather than a rule to remember.

---

## What was taken from where

## Grafted from B

1. **`ScrollPosition` ownership via `PrimaryScrollController` + `createScrollPosition`** — replaces A's entire physics-based arbitration. Decisive reason below in Disagreements.
2. **`sealed LayoutCorrection` as a returned value** (B's best idea). A and C both copy smooth_sheets' `dryApplyNewLayout`/`applyNewLayout` pair plus a post-hoc divergence assert (`smooth_sheets-1.0.3/lib/src/model.dart:345-361`). B has the activity return a `LayoutCorrection`, and both the dry pass and the commit call `correction.resolve(...)`. One implementation, nothing to keep in sync. Their runtime assert becomes our type; the remaining assert is a purity tripwire.
3. **`RenderPanelViewport` with `sizedByParent: true` and tight main-axis child constraints.** Verified: `/Users/obenkucuk/fvm/versions/3.44.9/packages/flutter/lib/src/rendering/object.dart:2847` is `_isRelayoutBoundary = !parentUsesSize || sizedByParent || constraints.isTight || parent == null`. So we are a boundary (per-frame `markNeedsLayout` never dirties the app tree) and the child is one (content-internal layout never dirties us). Only B argues the perf case from the framework rule.
4. **Dry-layout content measurement, not intrinsics.** Verified: `rendering/viewport.dart:1676` `sizedByParent => true` and `:1680-1683` `computeDryLayout => constraints.biggest` behind a bounded-axis assert. So `getDryLayout(bounded)` returns the right answer for a `ListView` and does not throw, where `getMinIntrinsicHeight` trips `debugThrowIfNotCheckingIntrinsics` (`:705-725`). A planned to assert-and-refuse (its own risk 5); C planned a real probe layout. B's is correct and cheaper than both.
5. **`PanelSizing {resize, translate, clip}`** as a per-panel detent-motion policy — this is where the research's "keep `DismissalMode.shrink`'s behaviour, re-implement as a layout policy" lands.
6. **Activity hierarchy split into `SelfDrivenActivity` / `ScrollDrivenActivity`**, with non-nullable `position` on the scroll branch. Fixes smooth_sheets' nullable `switch` (`scrollable.dart:147-152`).
7. **`AbsoluteDetent.edgeAttached` as a nullable per-detent override** defaulting to the placement — the cheap hedge on V6, which is worth 34pt on every absolute detent.

## Grafted from C

1. **`PanelAnchor` with `leading`/`trailing` resolved against `TextDirection`.** A and B both use absolute `AxisDirection.left/right`. A drawer that does not mirror in RTL is wrong, and this is not a preference.
2. **`sealed CrossAxisFit {fill, inset, centered}`** — C's single best idea. It makes the dialog stop being a special case (centring is a cross-axis policy), expresses iOS 26's 8.33pt side insets (V4) on any anchor, and keeps iPad form-sheet width a parameter rather than a constant (V7, sizes drifted 540×620 → 580×640 → 540×600).
3. **`Detent.dismissed` as a member of the detent list.** Not as C's mechanism (see Disagreements) but as the *declaration*: its presence is what enables travel below `minDetent` to become `EdgeOffset`. Its absence gives a dialog no drag-to-dismiss by construction, with no direction to get wrong.
4. **Distinct `Baseline` and `ViewportExtent` extension types.** Detents normalise to the baseline; the rubber band normalises to the viewport. They differ by ~96pt on an iPhone 17 Pro. C is the only design that types the difference — and A's own prose gets it wrong, normalising the rubber band to the baseline where the research says "chpwn asymptotes at one viewport" (line 345).
5. **`CustomDetent.identity` as a required parameter.** A closure is a fresh object every build; without an identity the detent *set* compares unequal every frame, and G10 says a set change snaps. **A does not have this and it is a live bug in A** — its `DetentSet` value equality would snap the panel on every rebuild that used `Detent.custom`.
6. **The pages-and-`onDidRemovePage` host shape**, which mirrors `NavigationStack` in this repo (`/Users/obenkucuk/dev/zenrouter/packages/zenrouter/lib/src/path/stack.dart:374-404`) rather than inventing a parallel slice type.
7. **C's research diligence, adopted as a correction.** C is right and the research is wrong: `smooth_sheets-1.0.3/lib/src/scrollable.dart:146` reads `// TODO: Stop scroll animations when a non-scrollable activity starts.` — it is not the nested-scrollable TODO. A and B both repeated the research's misattribution. The nesting claim is still true in effect; the citation is not.

## Dropped

- **A's `ScrollBehavior`/`applyPhysicsToUserOffset` arbitration** — kept only as a coverage backstop and escape detector, not as the mechanism.
- **A's microtask + `_SettledSimulation` activity swap** — unnecessary once we own the position.
- **A's `PanelSlice`** — a parallel page type that loses `Page` semantics (keys, `restorationId`, `arguments`).
- **B's single-scalar geometry**, and with it B's `createSimulation` seeding from `extent.over(base)`.
- **B's `didChangePrevious` geometry adoption** — deferred, not deleted; see Open Questions.
- **C's `Presence` as the dismissal drag axis** — kept as a *derived* read-only value for `PanelEntry`, never as the thing a finger drives.
- **C's bundling of `barrier`, `entry`, `handle` into `PanelPlacement`** — that conflates where a panel is with what it looks like arriving, and forces you to construct a placement to change a scrim.
- **C's `resizeAxis` field** — dead for four of five anchors; the centre anchor takes its axis directly.

---

## Where the three disagreed, and the calls

## 1. Scroll handoff mechanism — the largest disagreement, and it has a clean answer

**A:** inject through `ScrollBehavior`; split the delta inside `ScrollPhysics.applyPhysicsToUserOffset`. **B and C:** own the `ScrollPosition` through `PrimaryScrollController` + `ScrollController.createScrollPosition`.

Both mechanisms are real. I verified all of it:

- A's hook is genuine and universal. `scrollable.dart:618` is `_configuration = widget.scrollBehavior ?? ScrollConfiguration.of(context)`, unconditional in `didChangeDependencies` — no `primary` gate, no controller gate, no platform gate. `scroll_position_with_single_context.dart:129-132` calls `physics.applyPhysicsToUserOffset(this, delta)` with the live position, and it has exactly two callers in the whole framework (that one and `nested_scroll_view.dart:1308`). `scroll_configuration.dart:415-418` means a `shouldNotify` returning false causes no position churn. A's reading of the framework is accurate.
- B/C's hook is equally real. `scroll_view.dart:507-513` and `single_child_scroll_view.dart:253-258` both compute `effectivePrimary = primary ?? controller == null && PrimaryScrollController.shouldInherit(...)`, and `shouldInherit` (`primary_scroll_controller.dart:125-137`) gates on the platform set and an axis match.

**Call: B/C's mechanism, and it is not close — because owning the position eliminates A's own worst risk.**

A nominates its `BouncingScrollPhysics` shadow as "the single failure I would most want reviewed", and it is real: `scrollable.dart:622` applies the widget's physics *outermost*, and `scroll_physics.dart:710-716` does not delegate to `parent`. So `ListView(physics: BouncingScrollPhysics())` silently disables A's entire arbitration — the exact `SheetScrollConfiguration.disabled` trap the brief forbids, with a heuristic detector as the only guard. When the split lives in `PanelScrollPosition.drag`/`goBallistic` instead of in physics, **a user-supplied `physics:` cannot shadow it at all.** A's risk 1 (mutating panel state inside a method documented as a pure transformation) and risk 3 (the microtask + `_SettledSimulation` swap, needed only because `goBallistic` calls `goIdle()` on a null simulation, `scroll_position_with_single_context.dart:149-157`) also disappear. Three of A's top three risks are artefacts of not owning the position. The research says the same thing independently: it ranks `ScrollPosition` interception first of three and notes Flutter's own `CupertinoSheetRoute` and `smooth_sheets` both go there.

A's mechanism survives as the **coverage backstop**, which is a better job for it than being the mechanism.

## 2. Which scrollables escape, and how loudly — A is right about the problem, wrong about the fix

A is correct that `PrimaryScrollController` misses `controller:`, `primary: false`, bare `Scrollable`, and axis mismatch. B and C both answer with a `ScrollMetricsNotification` listener checking `Scrollable.of(ctx).position is! PanelScrollPosition`.

**Call: neither. Use A's `ScrollBehavior` channel as the detector.** `PanelScrollBehavior.getScrollPhysics` reaches *every* `Scrollable` in the subtree (`scrollable.dart:621`, unconditional). Our physics asks one question in `applyPhysicsToUserOffset`: is this position one of ours? If yes, pass straight through to `parent` — arbitration already happened. If no, this scrollable escaped, and we know it **synchronously, on the first delta, with the position in hand and the widget nameable** — where a notification listener fires a frame late and needs a `depth` filter. In release we degrade to a drag-time-only split; in debug we throw with the fix. A's registry-based backstop (`buildOverscrollIndicator` is called with `ScrollableDetails(controller: _effectiveScrollController)` at `scrollable.dart:995-1006`, so every position is reachable) is kept as a debug-only second net for the one case the physics channel cannot see: an escapee that *also* sets `physics:`.

## 3. Desktop — B and C found something the research did not, and it matters

`primary_scroll_controller.dart:24-28` defaults `automaticallyInheritForPlatforms` to `{android, iOS, fuchsia}`, and `smooth_sheets-1.0.3/lib/src/scrollable.dart:828-831` uses the bare constructor. So smooth_sheets' scroll↔sheet handoff **does nothing on macOS, Windows, Linux or desktop web** for a controller-less `ListView`. That is a second silent trap beyond the `disabled` default, absent from the research, found independently by B and C. **Call: pass `TargetPlatform.values.toSet()`, and make the platform sweep a test, not a comment.**

## 4. Dismissal seam — A's pixels beat C's fraction

A extends the drag axis below `minDetent` into `EdgeOffset`, in pixels. C routes it into a 0..1 `Presence`, dividing by the dismissal travel. C flags the divisor as its own third risk: "a wrong divisor makes a flick dismiss at visibly the wrong speed, and it will look like a physics bug rather than an arithmetic one." **Call: A's. There is no divisor to get wrong, and route progress is derived from it rather than driving it.** C's `Detent.dismissed` is kept as the declaration that switches the seam on.

## 5. Route progress — B's is a defect

B seeds `createSimulation` with `start: geometry.extent.over(base).value`. Dismissing from `.medium` therefore starts the route animation at 0.56, so the barrier begins fading from 56% opacity and a dialog cannot dismiss without resizing to nothing. This follows from the single scalar, not from a slip. **Call: presentation progress is derived from `EdgeOffset` and is 1.0 at every detent.**

## 6. S3, the `.scrolls` reading — A picks SwiftUI, B picks UIKit, C declines

Corrections #3 says both Apple documents are live and one is wrong. But the research also states, flatly: **"Trust the SDK header over the website"** (line 86), listing three further divergences where the header won. The SDK header is the UIKit one. **Call: B's reading, on the research's own stated rule, in C's three-value shape** (`resizesFromEdge` / `resizesAlways` / `scrollsFirst`), which separates the offset-0 precondition from the priority. Documented as a conflict in the doc comment, with the grabber bypassing it in all modes (S4).

## 7. Paging — all three are partly wrong

A invents `PanelSlice`. B adopts a sibling route's geometry via `didChangePrevious`, and admits it never traced the push path or the `pages:`-diff path — which is precisely the path zenrouter uses, through a Myers diff and a custom `ZenTransitionDelegate` that exists because Flutter's default delegate drops exit transitions (`stack.dart:381-383`). C makes `PanelPage` non-self-sufficient: its `PanelPageRoute` "carries no geometry of its own", so a bare `PanelPage` handed to zenrouter has no host — which breaks the one interop requirement.

**Call: an inner `Navigator` (A/C's mechanism, C's `pages` + `onDidRemovePage` shape), with `PanelPage` self-sufficient (A/B).** One page class, two roles: unhosted it creates a `PanelModel`; hosted it adopts the host's. B's objection to an `InheritedWidget` — sibling routes' overlay entries are not descendants — is correct and does not apply here, because an inner navigator's pages *are* descendants of the host route's content. B's adoption trick is the more elegant endpoint and is deferred to a spike, not adopted on faith.

## 8. Rubber-band normaliser — A says baseline, C says viewport

Research line 345-346: chpwn "asymptotes at one viewport". **Call: viewport.** C's separate `ViewportExtent` type is what stops this being re-confusable. A's *derivative* framing of the drag-end scale is right and C's *inverse* framing is subtly not — the drag-end quantity scales a velocity, so it is `map'(x)`, not `map⁻¹`. We need both functions; we do not conflate them.

---

## The design

All paths relative to `/Users/obenkucuk/dev/zenrouter/packages/shits/`. Flutter SDK citations are against `/Users/obenkucuk/fvm/versions/3.44.9/packages/flutter/lib/src/`.

# 1. Type vocabulary

## 1.1 Extension types (`lib/src/geometry/units.dart`)

Extension-type primary constructors cannot carry an initializer list, so none of these assert. Validation lives at the resolution boundary (`PanelBaseline.from`, `Detent.resolve`, `PanelModel.extent=`). None `implements double`, so `double`'s operators are not inherited — that is what makes the confusions below compile errors rather than wrong numbers.

```dart
/// A length along the span axis, in logical pixels, from the attachment edge to
/// the leading edge. The animated FRAME quantity. Finite, >= 0.
extension type const Extent(double px) {
  static const Extent zero = Extent(0);
  Extent operator +(Extent o) => Extent(px + o.px);
  Extent operator -(Extent o) => Extent(math.max(0, px - o.px));
  bool operator <(Extent o) => px < o.px;
  bool operator >(Extent o) => px > o.px;
  int compareTo(Extent o) => px.compareTo(o.px);
  Extent clampTo(Extent lo, Extent hi) => Extent(px.clamp(lo.px, hi.px));
  bool isCloseTo(Extent o, {required double devicePixelRatio}) =>
      (px - o.px).abs() < 0.5 / devicePixelRatio;
}

/// iOS `maxDetentValue`, generalised: the viewport span along the panel's span
/// axis minus the view padding at BOTH ends of that axis. The only thing a
/// [Fraction] may be resolved against.
extension type const Baseline(double px) {
  Extent get asExtent => Extent(px);
}

/// The raw viewport span along the span axis. NOT a detent baseline. The rubber
/// band's normaliser and nothing else.
extension type const ViewportExtent(double px) {}

/// A dimensionless multiplier of a [Baseline]. Negative mirrors, never clamps (G5).
extension type const Fraction(double value) {
  Extent of(Baseline b) => Extent((value * b.px).abs());
}

/// Displacement of the panel's attachment edge from the viewport's attachment
/// edge, along the span axis. Zero for an edge-attached panel at rest; positive
/// while entering, leaving, floating, or centred.
extension type const EdgeOffset(double px) {
  static const EdgeOffset zero = EdgeOffset(0);
  EdgeOffset operator +(EdgeOffset o) => EdgeOffset(px + o.px);
  /// Route progress. DERIVED, never driven. 1.0 at every detent.
  double presentationProgress(Extent e) =>
      e.px == 0 ? 0 : (1 - px / e.px).clamp(0.0, 1.0);
}

/// px/s along the span axis, positive when the panel is GROWING, for every
/// placement. Produced only by PanelAnchor.
extension type const ExtentVelocity(double pxPerSecond) {
  static const ExtentVelocity zero = ExtentVelocity(0);
  ExtentVelocity operator -() => ExtentVelocity(-pxPerSecond);
  bool get isGrowing => pxPerSecond > 0;
}

/// px/s in Flutter scroll space: positive when `ScrollPosition.pixels` rises.
extension type const ScrollVelocity(double pxPerSecond) {}

/// A position on the fused ballistic axis, [0, panelTravel + scrollableDistance].
@internal
extension type const FusedPosition(double px) {
  ({Extent extent, double scrollPixels}) split(FusedAxis a) => a.split(this);
}
```

Each type names the shipped bug it prevents:

| Type | Mistake made unrepresentable |
|:--|:--|
| `Extent` vs `Fraction` | `stupid_simple_sheet` animates a fraction of *its own child's* height (`SSS/lib/src/sheet_dismissal_transition.dart:64-67`, reference from `context.size.height` at `:41`). `snapPoint: 0.5` means half the content; an iOS detent means 0.56 of the container. Both `double` there. Here `Detent.height(0.56)` does not compile. |
| `Baseline` vs `ViewportExtent` | Resolving a detent against the raw viewport. On iPhone 17 Pro `.fraction(0.5)` is 437.0 against the viewport, 389.0 against the baseline, and `.medium` is 435.667. Three plausible numbers inside 50pt — this is research gap #1, and it is why Flutter's `_kTopGapRatio = 0.08 × screenHeight` is 8pt low on a 17 Pro and ~33pt low on SE-class. `Fraction.of` accepts only `Baseline`. |
| `Extent` vs `EdgeOffset` | Conflating "how big" with "how far it has come". Multiplying them is what makes a translate-only core unable to page: a page extent change H₁→H₂ moves the visible edge by `v·(H₁−H₂)` and an inner `ListView` gets a viewport of `H` while `v·H` is on screen. There is no operator between them. |
| `ExtentVelocity` vs `ScrollVelocity` | Sign inversion at the seam. Scroll-positive and panel-positive agree for a top sheet and oppose for a bottom sheet. `SSS` negates in four places inside forty lines (`stupid_simple_sheet.dart:407`, `:606`, `:615`) and ships inverted direction comments (`snapping_point.dart:254-268`, research defect 10). Conversion exists only on `PanelAnchor`. |
| `FusedPosition` | Handing a fused coordinate to `setPixels`, or an extent. In `smooth_sheets` all three are bare `double` in the same method (`SMOOTH/lib/src/scrollable.dart:294-329`), needing a ten-line defensive comment citing "infinite recursion … issues #207 and #212". |

**Honest limit, stated once in the library doc:** extension types erase. `someExtent == 0.56` compiles and is true, and `identical` sees through them. They prevent arithmetic and argument confusion, not `==` against the representation. No claim beyond that.

## 1.2 Sealed sets

```dart
// lib/src/geometry/anchor.dart — the ONLY file that knows a screen direction.
enum PanelAnchor {
  bottom, top, leading, trailing, center;

  Axis get spanAxis;                    // center: vertical
  bool get isDirectional => this == leading || this == trailing;
  AxisDirection resolve(TextDirection d);      // leading -> right in LTR, left in RTL
  Baseline baselineOf(Size viewport, EdgeInsets viewPadding);
  Extent attachedPadding(EdgeInsets viewPadding, TextDirection d);
  ExtentVelocity fromPointer(Velocity v, TextDirection d);
  ExtentVelocity fromScroll(ScrollVelocity v, TextDirection d);
  ScrollVelocity toScroll(ExtentVelocity v, TextDirection d);
  double extentDeltaFromScrollDelta(double delta, TextDirection d);
  Rect rectOf(Extent e, EdgeOffset o, PanelLayout l, CrossAxisFit fit);
}
```

`leading`/`trailing` resolving through `TextDirection` is why a drawer mirrors in RTL without the app doing anything, and it is the reason this is an anchor enum rather than an `AxisDirection` field.

```dart
// lib/src/geometry/placement.dart
sealed class Placement {
  const Placement();
  PanelAnchor get anchor;
  CrossAxisFit get crossFit;
  Axis get spanAxis => anchor.spanAxis;

  static const Placement bottom = EdgePlacement(anchor: PanelAnchor.bottom);
  static const Placement top    = EdgePlacement(anchor: PanelAnchor.top);
  static const Placement drawer = EdgePlacement(anchor: PanelAnchor.leading);
  static const Placement rail   = EdgePlacement(anchor: PanelAnchor.trailing);
  static const Placement dialog = CenterPlacement(spanAxis: Axis.vertical,
      crossFit: CrossAxisFit.centered(560));
}

final class EdgePlacement extends Placement {
  const EdgePlacement({
    required this.anchor,
    this.attachment = EdgeAttachment.edgeAttached,
    this.crossFit = const CrossAxisFit.fill(),
    this.anchorGap = 0.0,          // iOS 26 floats half sheets ~40pt up (V4)
  });
  @override final PanelAnchor anchor;
  final EdgeAttachment attachment;
  @override final CrossAxisFit crossFit;
  final double anchorGap;
}

final class CenterPlacement extends Placement {
  const CenterPlacement({required this.spanAxis, required this.crossFit});
  @override PanelAnchor get anchor => PanelAnchor.center;
  @override final Axis spanAxis;
  @override final CrossAxisFit crossFit;
  // No `attachment`: a centred panel is always floating (G6's other half).
}

enum EdgeAttachment { edgeAttached, floating }

sealed class CrossAxisFit {
  const factory CrossAxisFit.fill() = FillCross;                    // G8
  const factory CrossAxisFit.inset(EdgeInsets i) = InsetCross;      // iOS 26, V4
  const factory CrossAxisFit.centered(double maxCross) = CenteredCross; // iPad, V7
  (double offset, double extent) resolve(PanelAnchor a, PanelLayout l);
}
```

```dart
// lib/src/geometry/detent.dart
typedef DetentResolver = Extent? Function(PanelBaseline baseline);

sealed class Detent {
  const Detent();

  /// Distance from the attachment edge, or null if this detent declares itself
  /// INACTIVE for this context (G7). Not an error, not a zero.
  /// MUST be cheap and pure: iOS invokes its equivalent 7x per layout pass (G9).
  Extent? resolve(PanelBaseline baseline);

  /// Enables the dismissal seam. Resolves to Extent.zero; filtered out of the
  /// snap set and surfaced as ResolvedDetents.dismissible.
  static const Detent dismissed = DismissedDetent._();
  static const Detent full = FullDetent._();                   // iOS .large, G2
  /// iOS .medium. MEASURED 0.56 x baseline on four devices, two safe-area
  /// geometries, byte-identical at 435.667pt. NOT 0.5 (which gives 389.0).
  static const Detent medium = MediumDetent._();
  const factory Detent.fraction(Fraction f) = FractionDetent._;
  const factory Detent.height(Extent e, {bool? edgeAttached}) = AbsoluteDetent._;
  const factory Detent.content({bool clampToBaseline}) = ContentDetent._;
  const factory Detent.custom(DetentResolver resolve, {required Object identity})
      = CustomDetent._;
}
```

`resolve` takes a `PanelBaseline` and nothing else. There is no path from a `Size` to a resolved detent that skips the safe-area subtraction, and no path from any detent to `viewInsets`. `identity` is required because a fresh closure per build would otherwise read as a set mutation, which G10 says snaps.

```dart
// lib/src/model/correction.dart — B's idea, the "beat smooth_sheets" item.
sealed class LayoutCorrection {
  const LayoutCorrection();
  /// PURE. Called once to size, once to commit. Same function both times.
  Extent resolve(PanelLayout l, Extent current, ResolvedDetents d);

  const factory LayoutCorrection.freeze() = FreezeExtent;
  const factory LayoutCorrection.hold(Detent target) = HoldDetent;
  const factory LayoutCorrection.settle(Detent target, Duration remaining) = SettleWithin;
  const factory LayoutCorrection.resnap(ExtentVelocity v) = ResnapBallistic;
}

// lib/src/model/activity.dart
sealed class PanelActivity {
  PanelModel get owner;
  ExtentVelocity get velocity;
  LayoutCorrection get onLayoutChanged;   // pure, cheap, no notifications
  bool get isUserDriven;
  void dispose();
}
sealed class SelfDrivenActivity extends PanelActivity {}
final class IdlePanelActivity      extends SelfDrivenActivity { final Detent target; }
final class DragPanelActivity      extends SelfDrivenActivity implements Drag {}
final class BallisticPanelActivity extends SelfDrivenActivity { final Simulation sim; }
final class SettlingPanelActivity  extends SelfDrivenActivity { final Detent destination; }

sealed class ScrollDrivenActivity extends PanelActivity {
  PanelScrollPosition get position;       // NON-nullable. That is the branch's point.
}
final class ScrollDragActivity      extends ScrollDrivenActivity {}
final class ScrollBallisticActivity extends ScrollDrivenActivity { final FusedAxis axis; }
final class ScrollHoldActivity      extends ScrollDrivenActivity {}
```

```dart
sealed class PanelBarrier {                        // B3/B4: ONE mechanism.
  const factory PanelBarrier.modal({Color color}) = ModalBarrier_;
  const factory PanelBarrier.undimmedUpThrough(Detent d, {Color color}) = UndimmedBarrier;
  const factory PanelBarrier.none() = NoBarrier;
  ({Color? dim, bool blocksHits}) at(Extent e, ResolvedDetents d);  // one record
}

sealed class KeyboardPolicy {                      // research gap #2
  const factory KeyboardPolicy.expandToLargest() = ExpandToLargest;   // KB1
  const factory KeyboardPolicy.expandUpTo(Detent cap) = ExpandUpTo;   // iOS has no API
  const factory KeyboardPolicy.hold() = HoldForKeyboard;              // FB17890661
  Extent apply(Extent current, PanelLayout l, ResolvedDetents d);
}

sealed class PanelEntry {                          // the ONLY consumer of presentation
  const factory PanelEntry.slide() = SlideEntry;
  const factory PanelEntry.scaleFade({double from}) = ScaleFadeEntry;
  const factory PanelEntry.crossFade() = CrossFadeEntry;              // iOS 27 N2
  Widget build(BuildContext c, double progress, Placement p, Widget child);
}
```

**Deliberately enums, not sealed** (closed sets, no payload, no exhaustive-dispatch need): `EdgeAttachment`, `PanelSizing`, `PanelScrollPolicy`, `HandleVisibility`. Sealing them would be the decoration the brief forbids. `KeyboardPolicy` is sealed only because `expandUpTo` carries a `Detent`; if that variant is cut, cut the sealed class with it.

# 2. Geometry model

## 2.1 Two scalars, never multiplied

- **`Extent extent`** — the frame span from the attachment edge to the leading edge. Resized; content lays out inside it.
- **`EdgeOffset edgeOffset`** — displacement of the attachment edge from the viewport's. Translated.

Rule: `extent` clamps to `[detents.min, detents.max]` with rubber band above max; travel **below** `detents.min` becomes `edgeOffset`, and only when `Detent.dismissed` is in the resolved set. So detent motion is resize, dismissal is translation, and neither multiplies the other. `edgeOffset.presentationProgress(extent)` is the route animation value — derived, 1.0 at every detent, so a barrier at `.medium` is at full opacity and a dismissal seeds `createSimulation` from 1.0 regardless of which detent it started at.

## 2.2 Baseline

```dart
// lib/src/geometry/baseline.dart
@immutable
final class PanelBaseline {
  const PanelBaseline({
    required this.safeSpan, required this.viewportSpan,
    required this.attachedPadding, required this.crossSpan,
    required this.isCompactHeight, required this.spanAxis,
  });

  factory PanelBaseline.from({
    required Size viewport,
    required EdgeInsets viewPadding,  // MediaQuery.viewPaddingOf, NEVER paddingOf
    required Placement placement,
    required TextDirection textDirection,
  });

  final Baseline safeSpan;          // G1: span - BOTH safe insets on that axis
  final ViewportExtent viewportSpan;// rubber-band normaliser only
  final Extent attachedPadding;     // G6; zero when floating or centred
  final double crossSpan;           // G8: pinned at every detent
  final bool isCompactHeight;       // gates MediumDetent (G7)
  final Axis spanAxis;
}
```

**There is no `viewInsets` field and no `padding` field.** KB6 is thereby structural, not remembered: `MediaQueryData.padding` collapses toward 0 with the keyboard up while `viewPadding.bottom` keeps 34pt, so a design that can reach `padding` makes every detent silently 34pt shorter whenever a field is focused. Here a detent physically cannot see either.

Specialising G1 to vertical reproduces 874−62−34=778, 956−62−34=860, 844−47−34=763 exactly. Specialising it to horizontal gives a drawer whose full state stops at the landscape notch — the same promise, not an analogy. `MediumDetent.resolve` asserts `spanAxis == Axis.vertical`: 0.56 of a width is not a measurement of anything.

## 2.3 Detent set

```dart
// lib/src/geometry/detent_set.dart
@immutable
final class DetentSet {
  const DetentSet(this.detents);
  const DetentSet.single(Detent d) : detents = const [d];
  final List<Detent> detents;             // authoring order, never index-arithmeticked
  ResolvedDetents resolve(PanelBaseline b);
  // value equality; drives G10
}

@immutable
final class ResolvedDetents {
  /// Sorted ascending, inactive (null) dropped, Detent.dismissed excluded.
  final List<(Detent, Extent)> snaps;
  final bool dismissible;                 // Detent.dismissed was present and active
  Extent get min; Extent get max;
  Extent get travel => max - min;
  Extent? extentOf(Detent d);
  Detent nearestTo(Extent e);
  Extent? neighbourAbove(Extent e);
  Extent? neighbourBelow(Extent e);
  /// SDK header: an unknown selection shows the SMALLEST. Ours is the smallest
  /// non-dismissed, documented as a deliberate divergence.
  Extent select(Detent? d) => extentOf(d ?? snaps.first.$1) ?? min;
}
```

Sorted once at construction; **no index ever crosses the sorted/unsorted boundary**. Verified target: `smooth_sheets-1.0.3/lib/src/snap_grid.dart` builds `sortedSnaps` at `:251`, reads `snaps[index]` from the *unsorted* list at `:258-259` while recording `nearestIndex`, then returns `sortedSnaps[nearestIndex ± 1]` at `:271-272`. Our shape makes it unrepresentable rather than fixed.

## 2.4 Layout and the resize protocol

```dart
// lib/src/geometry/layout.dart
@immutable
final class PanelLayout {
  const PanelLayout({
    required this.baseline, required this.viewInsets,
    required this.contentExtent, required this.devicePixelRatio,
    required this.textDirection,
  });
  final PanelBaseline baseline;
  final EdgeInsets viewInsets;   // KeyboardPolicy's only reader
  final Extent? contentExtent;   // null => ContentDetent inactive this pass
  final double devicePixelRatio;
  final TextDirection textDirection;
  // full value equality + hashCode
}
```

```dart
// lib/src/model/panel_model.dart
final class PanelModel extends ChangeNotifier {
  PanelModel({required TickerProvider vsync, required PanelConfig config});

  Extent get extent;
  EdgeOffset get edgeOffset;
  PanelActivity get activity;
  ResolvedDetents get detents;
  double get presentationProgress => edgeOffset.presentationProgress(extent);

  /// Pure, no commit, no notification. Called by RenderPanel BEFORE laying out.
  Extent dryApplyLayout(PanelLayout next);
  /// Commits. Called AFTER laying out.
  void applyLayout(PanelLayout next);

  void beginActivity(PanelActivity a);
  void goIdle({required Detent target});
  void goBallistic(ExtentVelocity v);
  void settleTo(Detent d, {Duration? within});
  void animateTo(Detent d, {SpringDescription? spring});
  void updateConfig(PanelConfig next);   // G10 lives here
  ExtentVelocity takeExitVelocity();     // consumed once, then cleared
}
```

Both passes funnel through one expression, so they cannot disagree:

```dart
Extent _resolve(PanelLayout l) =>
    activity.onLayoutChanged.resolve(l, extent, _config.detents.resolve(l.baseline));
```

`applyLayout` early-outs on a single `PanelLayout ==` — `smooth_sheets` compares five fields by hand under `// TODO: Make the layout class immutable so that we can compare … by the equality operator` (`model.dart:330-337`). The surviving debug assert is a *purity* tripwire (`_resolve(l) == _resolve(l)` and no listener fired during resolve), not smooth_sheets' after-the-fact divergence check with exact `double` equality on a value fresh out of a spring (`model.dart:356-360`).

| Activity | `onLayoutChanged` | The case it exists for |
|:--|:--|:--|
| `Drag`, `ScrollDrag`, `ScrollHold` | `freeze()` | Keyboard opens mid-drag. `SSS` defect 7 (`shrink_transition.dart:160-163`): there is no second, stale reference height here to desync — the drag's accumulated position *is* the `Extent`. |
| `Idle` | `hold(target)` | Rotation; `viewInsets` change. KB7: the engine already springs `viewInsets` frame-by-frame off the real `CASpringAnimation`, so animating again double-animates. Plain `Padding`, never `AnimatedPadding`. |
| `Settling` | `settle(destination, remaining)` | Content grows mid-animation; the target is moving, so re-seeding a spring per frame chatters. |
| `Ballistic`, `ScrollBallistic` | `resnap(velocity)`, capped at 150 ms | A page's content settles just after a fling started. |

## 2.5 Render

```dart
// lib/src/render/render_panel.dart
class RenderPanel extends RenderBox with RenderObjectWithChildMixin<RenderBox> {
  @override bool get sizedByParent => true;
  @override Size computeDryLayout(BoxConstraints c) => c.biggest;

  @override
  void performLayout() {
    var l = _measureLayout(constraints);
    if (_config.detents.needsContentMeasure) {
      l = l.withContentExtent(_measureContent(constraints));   // DRY layout
    }
    final visible = _model.dryApplyLayout(l);
    final laid = switch (_sizing) {
      PanelSizing.resize => visible,
      PanelSizing.translate || PanelSizing.clip => _model.detents.max,
    };
    child!.layout(_tightOnSpanAxis(laid, l), parentUsesSize: false);  // TIGHT
    _model.applyLayout(l);                                            // assert here
    _paintRect = _placement.anchor.rectOf(visible, _model.edgeOffset, l,
                                          _placement.crossFit);
  }
}

enum PanelSizing { resize, translate, clip }
```

Two relayout-boundary facts, both from `rendering/object.dart:2847` (`_isRelayoutBoundary = !parentUsesSize || sizedByParent || constraints.isTight || parent == null`): `sizedByParent` makes **us** a boundary, so a per-frame `markNeedsLayout` never dirties the app tree above the panel; a **tight** main-axis child constraint makes the **child** one, so content-internal layout never dirties us. Frame-based geometry therefore costs one child layout per frame inside the panel subtree and nothing outside it.

`_measureContent` uses `child.getDryLayout(BoxConstraints(maxMain: baseline))`, not intrinsics. Verified: `rendering/viewport.dart:1676` `sizedByParent => true` and `:1680-1683` `computeDryLayout => constraints.biggest` behind `debugCheckHasBoundedAxis`, so a `ListView` returns `baseline` — where `getMinIntrinsicHeight` returns `0.0` and trips `debugThrowIfNotCheckingIntrinsics` (`:705-725`), which is exactly what `SSS`'s `_illegallyComputeMinIntrinsicHeight` suppresses (`shrink_transition.dart:154-163`, author's own comment: "FIXME: Hey! this feels illegal"). Memoised on `(constraints, child.debugLayoutCount)`; a debug assert fires if the resolved content extent oscillates across three consecutive frames.

## 2.6 Physics

```dart
// lib/src/physics/rubber_band.dart
/// chpwn's rubber band, normalised to the VIEWPORT (research line 345:
/// "chpwn asymptotes at one viewport"), NOT to the panel's current extent.
///   map(x)   = (1 - 1/(x*c/L + 1)) * L      asymptote: L
///   slope(x) = c / (x*c/L + 1)^2            slope(0) = c = 0.55
@immutable
final class RubberBand {
  const RubberBand({required this.viewport, this.c = 0.55});
  final ViewportExtent viewport;
  final double c;
  Extent map(double rawOvershoot);
  double slope(double rawOvershoot);      // the drag-end velocity scale
  double inverse(Extent applied);         // applied -> raw, for path bookkeeping
}
```

Drag time: `extent = limit + band.map(rawOvershoot)` over the **un-resisted accumulated** position, so the map is path-independent — 100px in one delta equals 100px in a hundred deltas. `smooth_sheets` integrates deltas in `kTouchSlop`-clamped fragments (`physics.dart:213-236`), which is not.

Drag end: `settleVelocity = fingerVelocity * band.slope(rawOvershoot)`. **The drag-end scale is the analytic derivative of the drag-time map**, so the two cannot disagree. Verified target: `SSS` uses `1.0/(1.0 + overshoot*R)` while dragging (`stupid_simple_sheet.dart:~557`) and `1.0/(maxExtent + overshoot*R)` at drag end (`:~600`) under the comment *"Scale the velocity by the same resistance factor that was applied during dragging"* — I read both; they are not the same factor, and neither is normalised.

```dart
// lib/src/physics/projection.dart
/// finalX = x + 0.49938*v, matching UIScrollViewDecelerationRateNormal (0.998)
/// to four significant figures. Flutter's own lineage comment: "0.998^1000 = ~0.135".
/// NOT 0.322. NOT ClampingScrollSimulation (Android's spline).
const double kDecelerationDrag = 0.135;
FusedPosition projectLanding(FusedPosition from, double v) =>
    FusedPosition(FrictionSimulation(kDecelerationDrag, from.px, v).finalX);
```

Snapping targets the resolved detent nearest the **projected** landing, not the next in direction — so S10 multi-detent jumps fall out. `FlingSnapPhysics` forbids skipping (`SSS/lib/src/snapping_point.dart:231-276`) and is `SSS`'s default; the research marks it "Default is wrong."

`lib/src/physics/motion.dart` pins its own `SpringDescription` constants (see Open Questions on `motor`).

# 3. Scroll handoff

## 3.1 Ownership — `PrimaryScrollController` + `createScrollPosition`

```dart
// lib/src/scroll/attachment.dart
PrimaryScrollController(
  controller: _panelController,
  scrollDirection: placement.spanAxis,
  automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
  child: ScrollConfiguration(
    behavior: PanelScrollBehavior(inner: ScrollConfiguration.of(context), link: _link),
    child: content,
  ),
)
```

`scroll_view.dart:507-513`: `effectivePrimary = primary ?? controller == null && PrimaryScrollController.shouldInherit(context, scrollDirection)`. A bare `ListView(children: [...])` has both null and takes ours. **No wrapper, no controller, no configuration object.** `single_child_scroll_view.dart:253-258` is identical, so `SingleChildScrollView` is covered too.

Three details that are not optional:
- `automaticallyInheritForPlatforms` defaults to `{android, iOS, fuchsia}` (`primary_scroll_controller.dart:24-28`). `smooth_sheets-1.0.3/lib/src/scrollable.dart:828-831` uses the bare constructor, so its handoff does nothing on desktop. Passing all platforms is the one line that makes a drawer work on macOS, and the platform sweep is a test.
- `shouldInherit` uses `findAncestorWidgetOfExactType<PrimaryScrollController>()`, so we publish the framework class, never a subclass.
- `scrollDirection: placement.spanAxis` is what makes a drawer capture horizontal scrollables and — correctly — leaves a horizontal `PageView` inside a bottom sheet unarbitrated.

`scroll_view.dart:529-532` inserts `PrimaryScrollController.none` below a `ScrollView` that inherited, so nested scrollables cannot double-attach. We inherit the framework's answer to nesting rather than inventing a worse one.

```dart
// lib/src/scroll/position.dart
final class PanelScrollController extends ScrollController {
  PanelScrollController(this._link);
  @override
  PanelScrollPosition createScrollPosition(
      ScrollPhysics physics, ScrollContext context, ScrollPosition? old) =>
    PanelScrollPosition(
      link: _link, context: context, oldPosition: old,
      // Without this, a list shorter than its viewport has
      // shouldAcceptUserOffset == false, setCanDrag(true) is never called, and
      // the panel never sees the gesture at all.
      physics: physics is AlwaysScrollableScrollPhysics
          ? physics : AlwaysScrollableScrollPhysics(parent: physics),
    );
  @override void attach(ScrollPosition p) { super.attach(p); _link.register(p); }
  @override void detach(ScrollPosition p) { super.detach(p); _link.unregister(p); }
}

final class PanelScrollPosition extends ScrollPositionWithSingleContext {
  PanelScrollLink? link;
  @override ScrollHoldController hold(VoidCallback cancel);
  @override Drag drag(DragStartDetails d, VoidCallback cancel);
  @override void goBallistic(double velocity);
  @override void goIdle();
  @override void absorb(ScrollPosition other);   // hands the link binding across
}
```

Exactly four overrides — the same four `smooth_sheets` uses, because everything else in `ScrollPositionWithSingleContext` flows through the `ScrollActivity` those four begin. `ScrollController.position` is never called: several sibling lists may attach at once and it throws when `positions.length != 1`. `absorb` matters because Flutter replaces positions on a physics or controller runtimeType change (`scrollable.dart:686-698`), and a link holding a disposed position is a use-after-free.

**Owning the position is what makes a user-supplied `physics:` harmless.** The split lives in `drag`/`goBallistic`, not in `ScrollPhysics`, so `ListView(physics: BouncingScrollPhysics())` — which does not delegate `applyPhysicsToUserOffset` to its parent (`scroll_physics.dart:710-716`) — cannot shadow arbitration.

## 3.2 The split

```dart
// lib/src/scroll/link.dart
final class PanelScrollLink {
  Extent preScroll(double delta, PanelScrollPosition p);   // panel takes first
  double  scroll(double remaining, PanelScrollPosition p); // list moves
  void    postScroll(double leftover, PanelScrollPosition p); // rubber band / refresh
  void    fling(ScrollVelocity v, PanelScrollPosition p);  // one fused simulation
}

enum PanelScrollPolicy { resizesFromEdge, resizesAlways, scrollsFirst }

bool _panelMayTake(ExtentVelocity v, PanelScrollPosition p) => switch (policy) {
  PanelScrollPolicy.scrollsFirst  => false,   // grabber still resizes (S4)
  PanelScrollPolicy.resizesAlways => v.isGrowing
      ? detents.neighbourAbove(extent) != null : true,
  // S1 + S2, the SDK header's precondition verbatim: "...and a descendent scroll
  // view is scrolled to top". S5 falls out — one detent means no neighbour above,
  // so scrolling simply scrolls, with no special case written.
  PanelScrollPolicy.resizesFromEdge => v.isGrowing
      ? detents.neighbourAbove(extent) != null && p.pixels <= p.minScrollExtent
      : p.pixels <= p.minScrollExtent,        // S6: shrink, then dismiss
};
```

Excess above `detents.max` goes through `RubberBand`; excess below `detents.min` becomes `EdgeOffset` when `detents.dismissible`, rubber-banded otherwise. `postScroll` returns whatever the panel declines to the scroll view **unconditionally**, so `RefreshIndicator` works with no flag — `smooth_sheets` makes this opt-in via `delegateUnhandledOverscrollToChild`.

Every `ScrollDrivenActivity` is constructed with both objects — the panel activity and the placeholder `ScrollActivity` that moves no pixels but dispatches `ScrollStart`/`Update`/`Overscroll`/`End` so `Scrollbar`, `RefreshIndicator` and app listeners keep working. A half-installed handoff is not constructible.

## 3.3 One fused ballistic simulation

```dart
// lib/src/physics/fused_axis.dart
final class FusedAxis {
  const FusedAxis({required this.panelTravel, required this.scrollableDistance,
                   required this.detents});
  FusedPosition positionOf(Extent e, double scrollPixels);
  ({Extent extent, double scrollPixels}) split(FusedPosition u);
}

/// friction | spring, C1-continuous at the seam u == panelTravel.
final class FusedSimulation extends Simulation {
  ({Extent extent, double scrollPixels}) sample(double t);
}
```

Project the landing with `FrictionSimulation(0.135, u0, v)`. Lands at or above the seam → the whole thing is friction (a scroll fling). Below → target is the detent nearest the projection; friction to the seam, then a spring seeded with the velocity **read at the seam**, so continuity is by construction rather than by comment. We never zero a velocity pointing away from the target the way `smooth_sheets` does (`physics.dart:114-118`) — that discards exactly the continuity we are building for.

`PanelScrollPosition.goBallistic` installs the real activity directly on the position; because we own it, there is no `goIdle()` stomp to dodge (`scroll_position_with_single_context.dart:149-157`) and no microtask trick. One `AnimationController`, one vsync, one simulation, both consumers.

**S7 is `[OPEN]` with no ground truth** — Compose transfers, FloatingPanel and gorhom destroy, Flutter's own `DraggableScrollableSheet` is asymmetric (flutter#116981). `MomentumCarry.both` is the default, following `NestedScrollView`'s single-simulation-over-combined-space template, documented as a deliberate choice and not a fidelity claim, with `intoPanelOnly` and `none` as one-line alternatives.

## 3.4 Coverage backstop and loud escape

```dart
// lib/src/scroll/behavior.dart
class PanelScrollBehavior extends ScrollBehavior {
  @override ScrollPhysics getScrollPhysics(BuildContext c) =>
      PanelScrollPhysics(link: link, parent: inner.getScrollPhysics(c));
  @override Widget buildOverscrollIndicator(BuildContext c, Widget w, ScrollableDetails d) =>
      _PanelPositionRegistrar(link: link, details: d,
          child: inner.buildOverscrollIndicator(c, w, d));
  @override bool shouldNotify(PanelScrollBehavior old) => old.link != link;
  // every other member forwards to `inner`
}

class PanelScrollPhysics extends ScrollPhysics {
  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (position is PanelScrollPosition) {
      return super.applyPhysicsToUserOffset(position, offset);  // we already arbitrated
    }
    link.reportEscape(position);   // debug: throw, naming the widget and both fixes
    return link.degradedSplit(position, offset);   // release: drag-time split only
  }
}
```

This is A's mechanism kept for the job it is actually best at. `scrollable.dart:618-621` reads the ambient behaviour unconditionally in `didChangeDependencies` — no `primary` gate, no controller gate, no platform gate — so **every** scrollable in the subtree gets this physics, including ones `PrimaryScrollController` cannot reach (`controller:`, `primary: false`, bare `Scrollable`, axis mismatch). Detection is synchronous, on the first delta, with the position in hand — where B's and C's `ScrollMetricsNotification` detectors fire a frame late and need a `depth` filter. `scroll_configuration.dart:415-418` plus `shouldNotify` over a long-lived `link` means no position churn.

One residual hole, documented and not hidden: a scrollable that escapes the controller **and** sets its own `physics:` is invisible to this channel. The registrar from `buildOverscrollIndicator` — which receives `ScrollableDetails(controller: _effectiveScrollController)` (`scrollable.dart:995-1006`), the live controller for every scrollable including the private fallback — is the debug-only second net: a registered position that moves under a drag without our physics being consulted throws. That is the anti-`SheetScrollConfiguration.disabled` clause: the failure mode exists and it cannot be quiet.

# 4. Placements

One `EdgePlacement(anchor, attachment, crossFit, anchorGap)` plus one `CenterPlacement(spanAxis, crossFit)`.

| | anchor | span axis | `safeSpan` | leading edge | pointer→extent | crossFit default |
|:--|:--|:--|:--|:--|:--|:--|
| bottom sheet | `bottom` | vertical | `H − vp.top − vp.bottom` | top | `−v.dy` | `fill` |
| top sheet | `top` | vertical | same | bottom | `+v.dy` | `fill` |
| drawer | `leading` | horizontal | `W − vp.left − vp.right` | trailing edge | `±v.dx` by `TextDirection` | `fill` |
| rail | `trailing` | horizontal | same | leading edge | `∓v.dx` by `TextDirection` | `fill` |
| dialog | `center` | chosen | same on that axis | both, symmetric | `−v.dy` | `centered(560)` |

Four things fall out that would otherwise be per-widget special cases:

**G8.** "Only the top edge moves; left, right and bottom are pinned" becomes "only the leading edge moves; the other three are pinned", implemented once in `PanelAnchor.rectOf`. For a drawer the pinned axis is vertical and the moving edge is the trailing one; the sentence is unchanged.

**G6.** `.height(h)` resolves to `content + baseline.attachedPadding`, where `attachedPadding` is the view padding at the attachment edge for an `edgeAttached` `EdgePlacement` and `Extent.zero` otherwise. A drawer's absolute detent absorbs a landscape notch the way a bottom sheet absorbs the home indicator — the same rule.

**The dialog is a different `edgeOffset` policy plus a `CrossAxisFit`, not a special case.** For `EdgePlacement`, `edgeOffset` is 0 at rest. For `CenterPlacement`, `edgeOffset = (viewportSpan − extent) / 2` at rest and entry adds to it (or `PanelEntry.scaleFade` renders it as scale+fade instead). Detent resolution is byte-identical. This is the same generalisation iOS 27 reached with `presentationPlacement(.center/.leading/.trailing)` (N1), so we are not inventing an axis Apple will contradict.

**Sign and direction are centralised.** `PanelAnchor` is the only file in the package that knows a screen direction or a `TextDirection`. Everything downstream — rubber band, projection, snapping, `FusedSimulation`, `createSimulation` — is placement-blind. That is what makes "five placements, one model" true rather than aspirational: the physics files never mention `bottom`.

A drawer inherits the whole detent vocabulary, the resize protocol and the fused axis. It does **not** inherit `MediumDetent`, whose 0.56 constant and compact-height inactivity are vertical iOS facts.

# 5. Paged API

```dart
// lib/src/route/panel_page.dart
class PanelPage<T> extends Page<T> {
  const PanelPage({
    super.key, super.name, super.arguments, super.restorationId,
    required this.child,
    this.detents = const DetentSet([Detent.dismissed, Detent.full]),
    this.initialDetent,
    this.placement = Placement.bottom,
    this.sizing = PanelSizing.resize,
    this.scrollPolicy = PanelScrollPolicy.resizesFromEdge,
    this.barrier = const PanelBarrier.modal(),
    this.keyboard = const KeyboardPolicy.expandToLargest(),
    this.entry = const PanelEntry.slide(),
    this.handle = HandleVisibility.automatic,     // C1: auto at 2+ active detents
    this.motion,
  }) : pages = null, onDidRemovePage = null;

  /// A panel hosting an inner declarative stack of PanelPages. The host owns the
  /// PanelModel; the inner pages adopt it. A page change re-targets the extent
  /// through the panel's own settle — there is no second motion model.
  const PanelPage.paged({
    super.key, super.name, super.arguments, super.restorationId,
    required List<PanelPage<Object?>> this.pages,
    required void Function(Page<Object?>) this.onDidRemovePage,
    this.placement = Placement.bottom,
    ...
  }) : child = null, detents = const DetentSet.single(Detent.full);

  @override Route<T> createRoute(BuildContext context) => PanelRoute<T>(page: this);
}

class PanelRoute<T> extends PopupRoute<T> {
  PanelRoute({required this.page});
  final PanelPage<T> page;

  /// Adopted from an enclosing PagedPanelScope when hosted; created otherwise.
  /// So a bare PanelPage works standalone in any Navigator — which IS the
  /// zenrouter interop requirement.
  PanelModel get model;
  bool get ownsModel;

  @override Color? get barrierColor => page.barrier.at(model.extent, model.detents).dim;
  @override bool get barrierDismissible => model.detents.dismissible;
  @override bool get opaque => false;
  @override bool get maintainState => true;            // K2: presenter retained
  @override Widget buildModalBarrier();                // B3/B4: one mechanism

  @override
  Simulation? createSimulation({required bool forward}) {
    final v = model.takeExitVelocity();                // consumed, never reused
    return page.motionOrDefault.createSimulation(
      start: controller!.value, end: forward ? 1.0 : 0.0,
      velocity: v.pxPerSecond / model.extent.px,       // exit travel, not baseline
    );
  }
}
```

`createSimulation` is first-party (`widgets/routes.dart:272-278`, invoked at `:344` in `didPush`): when non-null the controller uses `animateWith`/`animateBackWith` and **ignores** `transitionDuration` and the curve. Because the route animation is `edgeOffset.presentationProgress(extent)` — translation only, extent held separately — the seeding is exact and starts from 1.0 at every detent. `takeExitVelocity` clears the stash so a later programmatic pop cannot inherit a stale fling. `CupertinoSheetRoute` throws release velocity away entirely and runs a fixed `animateTo(300ms, easeOut)` (`cupertino/sheet.dart:1124-1143`, no spring anywhere in it); `smooth_sheets` seeds the sheet spring but runs a 300 ms curve at the route boundary.

`widgets/navigator.dart:3153` requires only `route.settings is Page`, and a `PopupRoute` qualifies — so `PanelPage` drops into `packages/zenrouter/lib/src/path/transition.dart:77-81` with no zenrouter change and no dependency in either direction:

```dart
StackTransition.custom<FiltersRoute>(
  builder: (context) => const FilterRoot(),
  pageBuilder: (context, routeKey, child) =>
      PanelPage(key: routeKey, child: child, detents: _peek),
)
```

## The MVP

```dart
class _PlacesState extends State<Places> {
  Place? _selected;

  static const _peek = DetentSet([
    Detent.dismissed,
    Detent.height(Extent(180)),   // WWDC25 iOS 26 sample peek
    Detent.medium,                // 0.56 x safeSpan; inactive in compact height
    Detent.full,                  // leading edge exactly at viewPadding.top
  ]);

  @override
  Widget build(BuildContext context) => Navigator(
    onDidRemovePage: (p) { /* ... */ },
    pages: [
      const MaterialPage(child: MapBackdrop()),
      PanelPage.paged(
        key: const ValueKey('places'),
        placement: Placement.bottom,
        barrier: const PanelBarrier.undimmedUpThrough(Detent.height(Extent(180))),
        onDidRemovePage: (_) => setState(() => _selected = null),
        pages: [
          PanelPage(
            key: const ValueKey('list'),
            detents: _peek,
            initialDetent: Detent.medium,
            // A plain ListView. No controller, no wrapper, no config object.
            child: ListView.builder(
              itemCount: 200,
              itemBuilder: (c, i) => ListTile(
                title: Text('Place $i'),
                onTap: () => setState(() => _selected = places[i]),
              ),
            ),
          ),
          if (_selected case final p?)
            PanelPage(
              key: ValueKey(p.id),
              detents: const DetentSet([Detent.dismissed, Detent.full]),
              initialDetent: Detent.full,
              child: PlaceDetail(p),
            ),
        ],
      ),
    ],
  );
}
```

Pushing the detail page while the panel sits at `.medium` with the list scrolled 300px is the whole model in one gesture: the detent set changes (four → two), the extent settles from 435.667 to 778 under the panel's own spring, the outgoing list's scroll offset is preserved, and the incoming page lays out at the panel's live frame extent throughout.

**Why the seam has no compounding-fraction problem.** The extent is one scalar owned by one model and animated by one thing — `PanelModel.settleTo`, which begins a `SettlingPanelActivity`. The inner route's own animation drives only the content cross-fade *inside* the frame; it never touches size. There is no fraction to compound because `EdgeOffset` is pixels and entry lives there, not in `extent`. `navigator_resizable` fails both ways structurally: `Size.lerp` off a `CurveTween` against a spring (`NR/lib/src/navigator_size_notifier.dart:120-132`) and a non-transition size change applied instantly and unanimated (`:64-71`).

**Which detent set applies during the transition:** the incoming page's, resolved immediately, with the extent animated into it. A drag begun mid-transition snaps to the destination's detents, never to one about to stop existing.

# 6. File layout

```
lib/shits.dart                          Sole export surface.

lib/src/geometry/units.dart             Extent, Baseline, ViewportExtent, Fraction,
                                        EdgeOffset, ExtentVelocity, ScrollVelocity, FusedPosition.
lib/src/geometry/anchor.dart            PanelAnchor. The ONLY site of a screen direction,
                                        a TextDirection, or a velocity sign.
lib/src/geometry/placement.dart         sealed Placement, EdgePlacement, CenterPlacement,
                                        EdgeAttachment, sealed CrossAxisFit.
lib/src/geometry/baseline.dart          PanelBaseline. No viewInsets field, no padding field (KB6).
lib/src/geometry/detent.dart            sealed Detent, seven kinds, resolve -> Extent? (G7).
lib/src/geometry/detent_set.dart        DetentSet (value equality, drives G10);
                                        ResolvedDetents (sorted once, no index crosses the sort).
lib/src/geometry/layout.dart            PanelLayout immutable value type.

lib/src/physics/rubber_band.dart        chpwn map + analytic slope + inverse; viewport-normalised.
lib/src/physics/projection.dart         kDecelerationDrag = 0.135; projectLanding.
lib/src/physics/snap.dart               Detent choice from a projected landing (yields S10).
lib/src/physics/fused_axis.dart         FusedAxis and the seam at panelTravel.
lib/src/physics/fused_simulation.dart   friction | spring, C1 at the seam. Pure maths.
lib/src/physics/motion.dart             Pinned SpringDescription constants. The only file
                                        that would import `motor`, if `motor` survives.

lib/src/model/panel_model.dart          Two scalars, activity, dry/applyLayout, G10 in updateConfig.
lib/src/model/correction.dart           sealed LayoutCorrection: freeze/hold/settle/resnap.
lib/src/model/activity.dart             sealed PanelActivity; SelfDriven*/ScrollDriven* branches.
lib/src/model/keyboard.dart             sealed KeyboardPolicy. The only reader of viewInsets.
lib/src/model/barrier.dart              sealed PanelBarrier; at() returns (dim, blocksHits).

lib/src/scroll/position.dart            PanelScrollController + PanelScrollPosition (four overrides).
lib/src/scroll/link.dart                The arbiter: pre/scroll/post/fling, position registry.
lib/src/scroll/attachment.dart          PrimaryScrollController wiring (all platforms, span axis).
lib/src/scroll/behavior.dart            PanelScrollBehavior + PanelScrollPhysics: coverage backstop,
                                        synchronous escape detection, degraded release split.
lib/src/scroll/activity.dart            FusedBallisticActivity + the three placeholder activities.

lib/src/render/render_panel.dart        sizedByParent, tight child, dry-layout content probe.
lib/src/render/panel_viewport.dart      Widget/element, MediaQuery -> PanelLayout bridge.
lib/src/render/panel_media_query.dart   Re-derives padding/viewPadding/viewInsets for content.
                                        PORTED from smooth_sheets' SheetMediaQuery (MIT), attributed.

lib/src/widgets/panel.dart              Panel: the non-modal host (B1/B8).
lib/src/widgets/scope.dart              PanelScope + PanelController + PanelMetrics.
lib/src/widgets/handle.dart             C1 auto-visibility at 2+ active detents (~36x5pt),
                                        C2 tap cycles, S4 always resizes.
lib/src/widgets/entry.dart              sealed PanelEntry. The only consumer of presentation progress.

lib/src/route/panel_page.dart           PanelPage<T> and PanelPage.paged.
lib/src/route/panel_route.dart          PanelRoute<T>: createSimulation, buildModalBarrier, adoption.
lib/src/route/paged_panel.dart          Inner Navigator, pages diff, PagedPanelScope, one settleTo.

test/fixtures/devices.dart              const PanelLayout fixtures for the four measured devices.
```

**Layering rule, enforced by an import test:** `geometry/` and `physics/` may import only `dart:math`, `package:flutter/physics.dart`, `package:flutter/painting.dart`, `package:meta`. `model/` adds `foundation`. Only `render/`, `scroll/`, `widgets/` and `route/` may import `package:flutter/widgets.dart`. This is what makes the measured iOS tables plain unit-test fixtures and the physics assertable against numeric differentiation rather than a screenshot.

---

## Against the six requirements

## 1. MVP = a two-page paged sheet — **fully met as a design, and it is the acceptance test**

Section 5 spells out the exact example, and the mechanism behind it is specified end to end: `PanelPage.paged` hosts an inner `Navigator`, `PagedPanelScope` hands the model down (visible, because inner pages are descendants of the host's content — unlike B's sibling-route case), the page diff calls `model.updateConfig`, and `updateConfig` implements G10. The one motion model is a structural consequence, not a policy. The acceptance test is stated: on every pump of the transition, the inner `ListView`'s `viewportDimension` equals the panel's visible extent, and the extent is monotone between the two resolved detents.

**Caveat, named:** the paged host is the *last* slice to build, not the first, and its shape is the one I changed most from all three inputs. It is fully specified but wholly untried.

## 2. Everything semantically meaningful and structured — **fully met, with one honest limit**

Nine sealed types and eight extension types, each with a named, cited mistake it prevents:

| Type | Prevents | Cite |
|:--|:--|:--|
| `Extent` / `Fraction` | fraction-of-content read as fraction-of-container | `SSS/lib/src/sheet_dismissal_transition.dart:64-67` |
| `Baseline` / `ViewportExtent` | detent against the raw viewport (research gap #1) | derived from G1/G4 |
| `Extent` / `EdgeOffset` | multiplying size by presence | research §"geometry cannot express iOS detents" |
| `ExtentVelocity` / `ScrollVelocity` | sign inversion at the seam | `SSS/lib/src/snapping_point.dart:254-268` |
| `FusedPosition` | fused coordinate into `setPixels` | `SMOOTH/lib/src/scrollable.dart:294-329` |
| `Detent.resolve -> Extent?` | forgetting G7 inactivity (Absent in all three prior arts) | coverage table |
| `sealed LayoutCorrection` | dry/apply divergence | `SMOOTH/lib/src/model.dart:345-361` |
| `ScrollDrivenActivity.position` non-null | nullable "who is driving me" | `SMOOTH/lib/src/scrollable.dart:147-152` |
| `PanelBarrier.at -> record` | "dimmed but interactive" | B3/B4 |
| `ResolvedDetents` sorted-only | index across the sort boundary | `SMOOTH/lib/src/snap_grid.dart:251-273` (read; confirmed) |
| `CustomDetent.identity` required | snap on every rebuild | G10 + closure identity |

And four things are deliberately **not** sealed — `EdgeAttachment`, `PanelSizing`, `PanelScrollPolicy`, `HandleVisibility` — because they are closed sets with no payload and sealing them would be decoration. `KeyboardPolicy` is sealed only because one variant carries a `Detent`; the design says to demote it to an enum if that variant is cut.

**Limit stated, not hidden:** extension types erase. `someExtent == 0.56` compiles and is true; `identical` sees through them; there is no runtime cost and no runtime check. The claim is that they move eleven specific, cited bug classes from runtime to compile time, and nothing more.

## 3. Updatable, driven by tests — **fully met at the layer boundary, partly sketched in content**

The architecture is what makes this real: `geometry/` and `physics/` import no binding, so the four measured devices are `const` fixtures in `test/fixtures/devices.dart` and physics is asserted against numeric differentiation rather than goldens. The layering is enforced by an import test rather than by review. Behavioural claims are asserted as **trace properties** — continuity, monotonicity, notification sequences, layout counts — which survive a spring-constant change but still fail if velocity is discarded.

Test files are named per module and the discipline is stated: `test/scroll/no_opt_in_test.dart` is written *before* the arbiter exists; `test/model/correction_test.dart` is written before the activity leaves are finalised, so two leaves with identical corrections get merged rather than shipped.

**Only sketched:** coverage targets are asserted (100% on the pure layers, 90% elsewhere) but no CI wiring is specified, and no test exists yet for the paged host beyond the acceptance property. This is the requirement most dependent on discipline rather than on structure.

## 4. Code quality must beat smooth_sheets — **fully met on the eleven named defects; partly sketched on the rest**

Every defect the research lists is either structurally unrepresentable or has a named regression test:

- snap-grid index bug → unrepresentable (`ResolvedDetents` exposes no unsorted indexable list) + a regression test that builds a descending set.
- dry/apply divergence → unrepresentable (`LayoutCorrection` is one function called twice).
- `SheetScrollConfiguration.disabled` default → there is no switch; escape is a debug throw and a release degradation.
- desktop `PrimaryScrollController` hole → `TargetPlatform.values.toSet()` plus a platform-sweep test. **This one is not in the research; B and C found it independently and I confirmed it at `smooth_sheets-1.0.3/lib/src/scrollable.dart:828-831`.**
- `BouncingSheetPhysics` divide-by-`bounceExtent` and infinite `maxVelocityLimit` → our normaliser is `viewportSpan`, which cannot be zero while a panel exists, with an assert saying so.
- velocity zeroed when pointing away from target → never discarded.
- mutable layout compared field-by-field → one `==`.
- `SSS`'s two rubber-band formulas → one formula and its analytic derivative, with a test asserting `slope(x)` equals the numeric derivative of `map` to 1e-6. **I read both `SSS` sites and confirmed the mismatch and the false comment.**
- non-normalised resistance → viewport-normalised, with a two-viewport equality test.
- `_illegallyComputeMinIntrinsicHeight` → dry layout, which returns the right answer and does not throw.
- two child layouts + intrinsics walk per frame → one child layout per frame, budgeted by a `debugLayoutCount` test.
- inverted direction comments → one `PanelAnchor` file, round-trip test across five placements.

**Only sketched:** everything else that constitutes code quality — doc-comment discipline, `debugFillProperties`, error messages, `toString`, disposal audits. The design names these nowhere. Beating a package on its known defects is not the same as beating it overall, and I should not claim it is.

## 5. Configurable placement from one model — **fully met for the model; the four non-sheet placements are an extrapolation and should be labelled as such**

Five placements are two sealed variants over one anchor enum. `PanelAnchor.rectOf` is the only function that produces a screen `Rect`; the physics files never mention `bottom`. `CrossAxisFit` makes the dialog a cross-axis policy rather than a widget. RTL mirroring is free. The falsifiable test is stated: `test/geometry/placement_test.dart` is **one body parameterised over all five placements**, and if any placement needs its own body the design has failed.

**Honestly sketched:** the entire research document measures iOS *sheets*. `safeSpan` for a drawer — width minus both horizontal safe insets — is an extrapolation from G1 and may simply be wrong; a native sidebar probably wants full width with the content handling insets. iOS 27's `presentationPlacement` (N1) is the only platform precedent, it is at beta 5, and it is absent from Apple's own June 2026 SwiftUI changelog (N5). The design should ship the drawer and the rail as *ours*, not as iOS-parallel, and say so in the doc comments. Only the bottom sheet has ground truth.

## 6. Automatic scroll/drag handoff — **met for the common case; the residual holes are enumerated and loud, which is the most that is achievable**

A bare `ListView(children: [...])`, `ListView.builder`, `CustomScrollView` and `SingleChildScrollView` all participate with no wrapper, no controller and no configuration object, on **every** platform. Verified against `scroll_view.dart:507-513` and `single_child_scroll_view.dart:253-258`. Nesting is the framework's own answer (`PrimaryScrollController.none` inserted at `scroll_view.dart:529-532`). There is no `disabled` flag because there is nothing to enable.

**What escapes, stated plainly and not buried:** `ListView(controller: myController)`, `primary: false`, a bare `Scrollable`, an axis-mismatched scrollable, and `TextField`'s internal scrollable (correctly — you do not want a text field driving the sheet). The `ScrollBehavior` backstop catches the first four synchronously on the first delta and either throws in debug or degrades to a drag-time split in release. The one case neither channel sees is an escapee that *also* sets `physics:` — the debug position registrar is the second net, and it is a heuristic.

**This is the requirement I would most want a second reviewer on**, and it is also where I most changed the inputs. The honest summary: "a plain `ListView` just works" is true and testable. "Any content just works" is false in all three designs and in every shipped package, and the difference here is that failure is loud and has a two-word fix (`PanelScrollController` is public) rather than silent. A's risk 1 stands in modified form: the escape count for code an average app would write is unmeasured, and if it turns out to be common, the answer is not a better backstop — it is that the no-opt-in claim needs qualifying in the README before anything else is built.

---

## Open questions

## 1. `motor` — the brief and the repo already disagree, and the repo is newer

The brief says "Dependencies: `motor ^1.1.0` and nothing else. Decided already — do not re-litigate." But `/Users/obenkucuk/dev/zenrouter/packages/shits/pubspec.yaml` (mtime 00:50, five minutes after the rest of the scaffold at 00:45) declares **no third-party dependencies**, with a comment: *"the spring model this package needs is a Flutter SDK factory — `SpringDescription.withDurationAndBounce` … and velocity continuity across a route boundary is `TransitionRoute.createSimulation`, first-party since 3.44.9. What a motion package would have added is four constants, and those are ours to pin."*

I did not re-litigate; I checked, because the two artefacts contradict each other and the designs all assume the brief:

- `SpringDescription.withDurationAndBounce` **is** first-party in 3.44.9, at `physics/spring_simulation.dart:70-82`.
- `motor-1.1.0/lib/src/motion.dart:457` — `CupertinoMotion.description` is literally `SpringDescription.withDurationAndBounce(...)`.
- `motor` pulls in `equatable` transitively.
- The 500-vs-550 ms default inconsistency the research flags is confirmed: `motion.dart:378` defaults to 550 ms, `:423` `CupertinoMotion.smooth()` to 500 ms — and the design pins its own constants either way.
- The research's own citation at line 320 (`[SRC physics/spring_simulation.dart:70-82]`) is a *Flutter* path, not a `motor` path. The research already says this.

**The owner must decide, and it is one file** — `lib/src/physics/motion.dart` — in all three designs and in the merge. My read: the pubspec is right and the brief is stale, but that is the owner's call, not mine.

## 2. V6 — worth 34pt on every absolute detent

Whether `.height(h)` adds `safeAreaInsets.bottom` at a *floating* partial detent on iOS 26. Measured contradictorily in the research: `.height(300)` gave `contentHeight = 300.0` with a frame of 334.0 on 26.5 (edge-attached rule held), which sits against the measured ~40pt bottom float at `.medium` (V4). The research says one simulator run settles it and to **do this before writing acceptance tests**. The design hedges with a nullable `AbsoluteDetent.edgeAttached` defaulting from the placement, so the answer is a one-line default change plus one test row — but the default is a guess until the run happens.

## 3. S7 — momentum across the seam

`[OPEN]` with no ground truth; the clones actively disagree. The design picks `MomentumCarry.both` on `NestedScrollView`'s precedent. **Nothing in a test will settle this — it needs hands on a device.** A fling that expands the panel *and* keeps scrolling may read as a loss of control. The policy is a one-line change; try all three before 1.0.

## 4. Paging mechanism — inner Navigator now, adoption later?

The design ships C's inner-Navigator host because B's `didChangePrevious` adoption is untraced against the push path and against zenrouter's declarative diff plus `ZenTransitionDelegate` (`/Users/obenkucuk/dev/zenrouter/packages/zenrouter/lib/src/path/stack.dart:381-383`). B's adoption is the more elegant endpoint — two adjacent zenrouter routes becoming one paged panel with no host — and the owner should decide whether it is a post-MVP spike or dropped. **The spike is cheap and decisive:** push a second `PanelPage` and assert exactly one `PanelModel` exists after exactly one pump, then repeat through a `NavigationStack`.

## 5. Is `PanelRoute` a `PopupRoute` or a transparent `PageRoute`?

`widgets/navigator.dart:3153` permits a `PopupRoute` as a page-based entry, but this repo already ships `ZenTransitionDelegate` precisely because Flutter's default delegate drops a page's exit transition when anything sits above it. A non-opaque `PopupRoute` mid-stack in a declarative `pages` list is not well-trodden. C flags this; A and B do not. One test settles it: put a `PanelPage` mid-stack in a zenrouter path and pop a page beneath it.

## 6. The `PrimaryScrollController` hijack

Everything inside the panel that reaches for the ambient primary controller now gets ours: `Scaffold`'s status-bar-tap scroll-to-top, `ScrollAction`'s PageUp/PageDown, `NestedScrollView`'s outer controller. And ours throws on `.position` when two lists are attached. Both B and C flag this. Decide whether `PanelScrollController` forwards to a captured ancestor (needs a merged `positions` view, not a drop-in) or whether the hijack is simply documented. **Test that settles it:** a full `Scaffold` with an `AppBar` inside a panel.

## 7. The no-opt-in claim, measured rather than asserted

Before anything else is built, build the MVP three more ways — with a `RefreshIndicator`, with a `TabBarView` of lists, and with a `Form` containing a `TextField` — and count how many need `PanelScrollController`. If it is more than zero for code an average app would write, requirement 6's claim needs qualifying in the README on day one, not discovered at 0.3.0.

## 8. Package name

`shits` is the directory and the pubspec name. If this is ever published to pub.dev the owner should confirm that is intended.

## 9. Scope line on the barrier

`PanelBarrier` is in scope because B3/B4 make dimming and hit-testing one mechanism, and the Maps recipe is a stated architecture requirement. But a scrim is arguably the chrome that was excluded. The line drawn here — hit-testing and a flat colour in; blur, glass, corners and stack-back out — is defensible but it is a line, and the next person may reasonably draw it elsewhere.

---

## First slice

## The slice

**A single non-paged bottom sheet with three detents and a bare `ListView`, dragged and flung, with no dismissal and no route.** Concretely: `Panel` (the plain widget, not the route), `PanelPage`, `PanelRoute` and the whole `route/` directory are all out. `EdgeOffset` exists in the type vocabulary and is pinned to `EdgeOffset.zero`.

Files, in build order:

1. `lib/src/geometry/units.dart`, `anchor.dart` (bottom only, the other four anchors `UnimplementedError`), `baseline.dart`, `detent.dart` (`full`, `medium`, `fraction`, `height` — no `content`, no `custom`, no `dismissed`), `detent_set.dart`, `layout.dart`.
2. `lib/src/physics/rubber_band.dart`, `projection.dart`, `snap.dart`.
3. `lib/src/model/correction.dart`, `activity.dart` (`Idle`, `Drag`, `Settling`, `ScrollDrag`, `ScrollBallistic` — five leaves, not nine), `panel_model.dart`.
4. `lib/src/render/render_panel.dart` (`PanelSizing.resize` only), `panel_viewport.dart`.
5. `lib/src/scroll/position.dart`, `link.dart`, `attachment.dart`, `behavior.dart`, `activity.dart`.
6. `lib/src/widgets/panel.dart`, `scope.dart`.

**Why this is the right cut.** It is the smallest thing that exercises the two claims everything else rests on — that the detent baseline is right, and that a bare `ListView` hands off with no opt-in — while touching neither the route boundary nor paging, which are the two most speculative parts of the design. It is also the slice that would falsify the spine cheapest: if `sizedByParent` + tight-child does not hold the layout budget, or if `PrimaryScrollController` capture is thinner than measured, both show up here and the design changes before anything is built on top.

## Tests that prove it, in the order they are written

**Written before the code they cover:**

`test/scroll/no_opt_in_test.dart` — written **first, before the arbiter exists**. A matrix over content forms, each a bare widget with nothing panel-aware in it:

| content | expected |
|:--|:--|
| `ListView(children: ...)` | hands off |
| `ListView.builder` | hands off |
| `ListView(controller: appController)` | debug `FlutterError` naming the widget and both fixes |
| `ListView(primary: false)` | debug `FlutterError` |
| `ListView(controller: PanelScrollController())` | hands off |
| `CustomScrollView` | hands off |
| `SingleChildScrollView` | hands off |
| `ListView(physics: AlwaysScrollableScrollPhysics())` | hands off |
| `ListView(physics: BouncingScrollPhysics())` | hands off — owning the position makes this immune |
| `ListView` nested in a `ListView` | inner drag never reaches the panel |
| every row again under `TargetPlatform.macOS` and `.windows` | identical results |

The desktop rows are the ones that fail on the default `automaticallyInheritForPlatforms` and are the regression for the `smooth_sheets` hole I confirmed at `scrollable.dart:828-831`.

`test/model/correction_test.dart` — written **before the activity leaves are finalised**. An exhaustive `switch` over every `PanelActivity` leaf, so adding a leaf without a test is a compile error. For each: `c.resolve(l,e,d) == c.resolve(l,e,d)` and zero listener calls (purity), then the per-policy behaviour. **If two leaves have identical corrections and identical tick behaviour, merge them before shipping** — this is the test that keeps the sealed set from becoming nine classes with six real behaviours.

**Written alongside:**

`test/geometry/baseline_test.dart` — the measured table as a fixture:

```dart
const devices = [
  (name: '17 Pro', size: Size(402, 874), vp: EdgeInsets.only(top: 62, bottom: 34), base: 778.0),
  (name: '17 PM',  size: Size(440, 956), vp: EdgeInsets.only(top: 62, bottom: 34), base: 860.0),
  (name: '17',     size: Size(393, 844), vp: EdgeInsets.only(top: 47, bottom: 34), base: 763.0),
];
```

`safeSpan == base` on every row. And the KB6 structural test: raise `viewInsets.bottom` from 0 to 336 with `viewPadding.bottom` unchanged and assert every resolved detent is byte-identical — which passes trivially, because `PanelBaseline` has no `viewInsets` field. That is KB6 proved by construction.

`test/geometry/detent_test.dart` —
- G2: `Detent.full.resolve(b)!.px == b.safeSpan.px` **exactly** (measured ratio 1.0000 on 4/4), all rows.
- G4: on the 778 row `Detent.medium` is 435.667 ± 1e-2, **and in the same test** `Detent.fraction(Fraction(0.5))` is 389.0. The second assertion exists solely so that anyone who "simplifies" 0.56 to 0.5 fails loudly.
- G3 derived: `viewportHeight − frame(full).top == viewPadding.top`, all rows — and an explicit assertion that it is **not** `0.08 × 874 == 69.9`, the constant `cupertino/sheet.dart:30` uses.
- G5: `Detent.fraction(Fraction(-0.2))` equals `Fraction(0.2)`, mirrored not clamped, ≈155.6.
- G6: `Detent.height(Extent(200))` → 234 edge-attached with `vp.bottom == 34`, → 200 floating. **Both directions asserted, because V6 is unresolved; this is the single test row that changes when the simulator run settles it.**
- G7: `Detent.medium.resolve(compactBaseline) == null`, and a set containing it resolves to one fewer entry with no index shifted.
- No floor: `Detent.height(Extent(10))` resolves to 10 + inset, never 44.

`test/geometry/detent_set_test.dart` — build a set in **descending** authoring order, resolve, assert `neighbourAbove`/`neighbourBelow`/`nearestTo` are correct. `smooth_sheets-1.0.3/lib/src/snap_grid.dart:251-273` fails this; we cannot.

`test/physics/rubber_band_test.dart` —
- `slope(x) == (map(x+h) − map(x−h)) / 2h` to 1e-6 over `x ∈ [0, 3L]`. **This is the test that makes `SSS`'s defect-5 class inexpressible: the two formulas are one formula and its derivative.**
- Path independence: 100 deltas of 1px equals one delta of 100px to 1e-9.
- Asymptote: `map(1e6) < L` and `> 0.99L`. `slope(0) == 0.55`, not `BouncingScrollPhysics`' 0.52.
- Normalisation: equal `x/L` gives equal `map(x)/L` for two different `L` — `SSS` defect 6.
- Displacement at 400pt of raw overdrag matches chpwn's 0.431, not Flutter's 0.130.

`test/physics/projection_test.dart` — `projectLanding(0, 1000) == 499.38 ± 0.05`; plus a source-grep test asserting `0.322` appears nowhere in `lib/` and `ClampingScrollSimulation` is not imported.

`test/render/render_panel_test.dart` — drive `RenderPanel.layout()` directly, no `WidgetTester`:
- child receives `BoxConstraints.tightFor(height: extent)`; changing the extent changes them.
- **Boundary proof downward:** after `child.markNeedsLayout()`, `panel.debugNeedsLayout == false`.
- **Boundary proof upward:** after `panel.markNeedsLayout()`, the parent's `debugNeedsLayout == false`.
- **Layout budget:** 60 extent changes increment `child.debugLayoutCount` exactly 60 times. This is the standing guard against re-creating `SSS`'s two-layouts-plus-intrinsics per frame.

`test/scroll/split_test.dart` — deterministic `startGesture` + `moveBy`, reading extent and `position.pixels` after each pump: S1 (drag up grows before scrolling), S2 (away from offset 0 the list owns both directions), S5 (one detent → pure scroll, no special case in the code), S6 (drag down at offset 0 shrinks). Then all three `PanelScrollPolicy` values over the same steps.

`test/scroll/fused_ballistic_test.dart` — `tester.fling`, then assert: exactly **one** ballistic activity runs for the whole settle (counted through a spy), the panel lands on a resolved detent, no spurious `ScrollEnd`/`ScrollStart` pair appears in a `NotificationListener` trace, and a 3000 px/s fling from the smallest detent lands past the middle one while 400 px/s does not (**S10** — the behaviour `FlingSnapPhysics` forbids and `SSS` ships as its default).

`test/architecture/imports_test.dart` — `geometry/` and `physics/` import no `package:flutter/widgets.dart`. Cheap, and it is what keeps every test above device-free.

## The falsification criteria

The slice has failed, and the design must change before anything is built on it, if any of these hold:

1. Any row of `no_opt_in_test.dart` needs a wrapper or a config object to pass.
2. `child.debugLayoutCount` exceeds one per frame during a steady drag with no `ContentDetent` present.
3. `slope` and the numeric derivative of `map` disagree above 1e-6 — meaning the rubber band is two functions after all.
4. The fused ballistic needs more than one `Simulation` or more than one ticker.
5. `PanelBaseline` acquires a `viewInsets` field or a `padding` field for any reason.

---

# AMENDMENTS (owner, 2026-08-15) — these override the body above

## A1. A detent value and a frame extent are two types, and G2/G3 are settled

The first implementation used one `Extent` for both and shipped every ratio detent 34pt
short. The three measured facts reconcile only one way, and it needs no simulator run:

- **G6, verbatim from the SDK header:** `.height(200)` gives a sheet whose height is
  `200 + safeAreaInsets.bottom` **when edge-attached**. So a detent's resolved value is a
  *content* span inside the panel's safe area; the frame adds the attachment padding.
- **G2, measured:** `.large` resolves to exactly `maxDetentValue` = 778 on a 17 Pro.
- Apply G6 to G2: frame = 778 + 34 = **812**, top = 874 − 812 = **62** = `viewPadding.top`,
  which is **G3**. All three hold.
- Independently derived from Flutter's own constant: `_kTopGapRatio` gives
  `0.92 × 874 = 804.08`, and this document already records Flutter as ~8pt low on a 17 Pro
  → 812. On an SE-class device the bottom inset is 0 and both readings coincide, which is
  why only the 17 Pro row discriminates.

**Therefore:**

- `Detent.resolve(PanelBaseline) → DetentValue?` — a new extension type over `double`,
  meaning *the value iOS's `resolvedValue(in:)` returns*: a content span within the panel's
  safe area. `.full` returns the baseline's safe span exactly, so the measured assertion
  stays as measured.
- `PanelBaseline.frameOf(DetentValue) → Extent` is the **only** conversion, and it adds
  `attachedPadding`. `Extent` keeps its current meaning — a frame span — and `rectOf` keeps
  taking one.
- This makes the four detent kinds agree. Today `.height(Extent(778))` resolves to 812
  while `.full` resolves to 778, so a set containing both has a maximum resting height
  greater than the maximum it is told exists. That becomes unrepresentable.
- V6 stays open **only for the floating case**: whether a floating partial detent also
  absorbs the bottom inset. Edge-attached is settled. The hedge stays where it is.

## A2. `presentationProgress` is wrong in this document, not just in the code

`1 - px/extent.px` assumes the offset is zero at rest. It is not for two of the five
anchors: a centred dialog rests at `edgeOffset = (viewportSpan − extent)/2`, so a 300pt
dialog fully visible in an 874pt viewport reports 0.043 — a barrier 4% opaque behind a
fully-present dialog, and a route simulation seeded from 0.043. That is the same defect
this document rejects design B for.

Progress must be measured against the **resting** offset for the placement, not against
zero: `1 - (px - restingOffset) / (enteringSpan)`, where a bottom sheet's resting offset is
zero and a dialog's is `(viewportSpan − extent)/2`. Whoever implements the placement layer
owns the exact form; what is fixed here is that zero is not the datum.

## A3. Validation belongs in `resolve`

`resolve` is named in this document as the validation boundary and validates nothing.
`.height(Extent(-100))` resolves to −66 and reaches `rectOf` as an inverted rect;
`.fraction(Fraction(nan))` resolves to the full span, because `num.clamp` orders NaN above
the upper limit, making a NaN fraction silently indistinguishable from `.full`. Both are
programmer errors and both must assert in debug with a message naming the value.

## A4. A `.medium`-only set is legal

iOS accepts `sheet.detents = [.medium]` and shows a full sheet in compact height. Asserting
on it hard-fails a supported configuration from inside a layout pass on every frame after
rotation. The empty-resolution path is the *release* behaviour and must be reachable by a
test rather than hidden behind `coverage:ignore`.

## A5. Anything unsettled is a named policy with a default, never a baked-in choice

Owner's standing instruction. Two kinds of decision keep coming up: ones that are a matter
of *feel* and cannot be settled by a test, and ones that are a matter of *fact* we have not
measured yet. Neither may be hardcoded. Each becomes a named type or parameter with a
documented default, so changing it later is one line and a test row rather than a rewrite —
and so the place we suspect is wrong is findable by name.

The rule for telling them apart: **a measured fact is a constant, an unmeasured or
subjective one is a policy.** `.medium == 0.56 × baseline` is measured on four devices, so
it is a constant with the measurement cited. Everything below is not.

Already policies, keep them so: `SnapPolicy`, `PanelSizing`, `MomentumCarry`,
`KeyboardPolicy`, `EdgeAttachment`, the rubber band's resistance coefficient.

Must become policies, with the default named and both ends tested:

- **`kCompactHeightThreshold = 480.0`** — the builder flagged it as the one invented number
  in the geometry layer. Name it, document it as unmeasured, make it overridable.
- **Floating absorption (V6)** — whether a floating partial detent also absorbs the bottom
  inset. The hedge currently sits on `AbsoluteDetent`; the builder's own analysis says the
  real seam is `PanelBaseline`. Put it there, as a policy, so one change moves every detent
  kind at once.
- **The baseline derivation per anchor** — `safeSpan` for a drawer is an extrapolation from
  a document that only measured sheets, and may simply be wrong; a native sidebar probably
  wants the full span with the content handling insets. Make the derivation a policy per
  anchor rather than one formula that silently claims iOS parity it does not have.
- **The dismissal threshold and the fling-to-dismiss velocity** — feel, not fact.

A policy is only worth the name if both ends are tested. A default nobody has tried the
other side of is a hardcoded choice with extra steps.

## A6. Coverage is proved by porting other packages' examples, not asserted

Owner's call, and it replaces "we believe this covers the space" with something falsifiable.
Once the widget layer exists, the example set is built by **porting**:

- every tutorial and example in `smooth_sheets` (MIT, repo `fujidaiti/smooth_sheets`), and
- every example in the latest `stupid_simple_sheet` (MIT, repo
  `whynotmake-it/rivership`, package `stupid_simple_sheet` — read the *current* source, not
  the 1.0.0-dev.2 the research document analysed).

Each port is an acceptance test: if it can be written against `shits` without reaching past
the public API, that capability is covered. **Any port that cannot be written names a gap,
and the gap goes on the list rather than being worked around in the example.** That is the
whole value of the exercise — a port that quietly uses a private hook proves nothing.

Both are MIT, so porting is legal; attribute the origin in each example's header and keep
the example's own name so the mapping is obvious.

Record the result as a table — example, ported yes/no, and for each no, the missing
capability. That table is the coverage claim, and it is the only form of the claim allowed
in the README.

### A6.1 — Apple Maps as the third source, walked rather than remembered

Owner's addition. Beyond the two packages' example sets, Maps is the reference app for the
hardest combination this design claims to support: a non-modal search sheet that the map
stays interactive behind, and then a *second* sheet opening on top of it when a place is
tapped — sheet over sheet, each with its own detents, the lower one still there.

**Walk the real app before writing the example.** The iOS simulator on this machine runs
iOS 26.5 and a real iPhone on 27.0 is available, so this is observation, not recollection:
open Maps, go through every state the search sheet has, and record what actually happens at
each — which detents exist, whether the background dims and at which detent it starts,
whether the lower sheet keeps its scroll position, what the second sheet's own detents are,
what a drag on the lower sheet does while the upper one is open, and what dismissing the
upper one restores.

Write that down as observations with the state that produced them, the way the research
document does, *then* build the example. An example built from memory of an app proves
nothing; one built from a walked, recorded spec is the acceptance test for B3/B4 and for
sheet-over-sheet at once.

Timing: when the widget layer exists. It is the last and most demanding of the ports, not
the first.

### A6.2 — Instagram Reels' comment sheet as the fourth source

Owner's addition, and it covers a different corner from Maps. Maps is about *sheet over
sheet* with an interactive background; Reels is about a sheet that **rearranges what is
behind it** and about **the keyboard**, which is the gap the research found unclaimed by
every existing package.

The axes worth walking it for — as questions to answer by observation, not claims:

- Does the video move or scale as the sheet arrives, and is that tied to the sheet's
  position continuously or only to its resting detent? This is the background-transform
  case, and whether it is continuous decides whether the panel must publish its position as
  a listenable or merely its detent.
- Is the background dimmed at all, and does the video keep playing and stay tappable? That
  is B3/B4 — dimming and hit-testing as one mechanism — from the other side from Maps.
- **What the keyboard does.** Tapping the comment field is the case the research calls KB1,
  keyboard-forced detent growth, and rates *partial* in both packages with an open bug in
  one. Record exactly: does the sheet grow to a larger detent, does it merely translate, and
  what happens to the comment list's scroll position while it does.
- **The text field is the interesting escape.** The design says `TextField`'s internal
  scrollable correctly does *not* drive the panel — you do not want typing to resize the
  sheet. Reels is a sheet with a text field and a scrolling list in it at once, so it is the
  acceptance test for that boundary rather than a hypothetical.
- What dismisses it: a drag from the list at scroll offset zero, a drag on the handle, a tap
  outside, and whether any of those differ while the keyboard is up.

Same discipline as A6.1: **walk it and write the observations down with the state that
produced them, then build the example.** Android is the convenient surface here — the
Samsung on this machine is wired and adb-driven — so the walk can be recorded frame by
frame rather than remembered.

## A7. Frame drops and needless rebuilds are worked after the first examples, not before

Owner's scheduling call. Perf is measured against something that exists: until an example
runs, a rebuild budget is a guess. So the order is — widget layer, first ported examples,
*then* a perf pass, and from then on it stays a standing property rather than a one-off.

The instruments are already established in this repo and should be reused rather than
reinvented:

- **Element rebuilds per notification** — `debugProfileBuildsEnabled = true` plus
  `debugOnRebuildDirtyWidget`, counting rebuilt widget types. Assert on *names that must not
  appear* rather than on a count: the number moves with Flutter, "the navigator is not
  rebuilt by an idle notification" does not.
- **Repaints per frame** — `debugOnProfilePaint`, counting render objects painted in one
  pumped frame. This is how the tab-repaint work in `zenrouter` was measured (22 down to 11)
  and it is exactly the instrument for a panel that animates over a static background.
- **Layouts per frame** — the `debugLayoutCount` budget this document already specifies. One
  child layout per frame is the target; `smooth_sheets` runs two plus an intrinsics walk.

Each finding follows the same discipline as everywhere else here: reproduce it with a probe
first, fix it, then prove the test is load-bearing by disabling the fix and watching it go
red. A perf test that cannot fail is worse than no perf test, because it certifies.

### A6.3 — The coverage table, enumerated

Counted from the sources on this machine rather than from memory:
`smooth_sheets-1.0.3/example` (MIT) and `stupid_simple_sheet-1.0.0-dev.2/example` (MIT).
Every row is an acceptance test. **A port that reaches past the public API, or that quietly
drops the capability it was demonstrating, counts as a failure, not a pass.**

#### smooth_sheets — tutorials (22)

| # | example | notes |
|:--|:--|:--|
| 1 | `basic_sheet` | |
| 2 | `scrollable_sheet` | the no-opt-in claim, end to end |
| 3 | `physics_and_snap_grid` | our `SnapPolicy` and `RubberBand` |
| 4 | `tweak_bouncing_effect` | `bandResistance` is a config field for this reason |
| 5 | `sheet_controller` | |
| 6 | `sheet_padding` | |
| 7 | `bottom_bar_visibility` | the sticky-bar case: a bar pinned to the *viewport* edge, not the content's |
| 8 | `imperative_modal_sheet` | |
| 9 | `declarative_modal_sheet` | |
| 10 | `imperative_modal_custom_barrier_sheet` | `PanelBarrier` |
| 11 | `cupertino_modal_sheet` | card stacking |
| 12 | `ios_style_declarative_modal_navigation_sheet` | |
| 13 | `imperative_paged_sheet` | |
| 14 | `declarative_paged_sheet` | the MVP's own shape |
| 15 | `paged_sheet_and_keyboard` | KB1, the gap the research found unclaimed |
| 16 | `paged_sheet_with_auto_route` | port the *shape* onto zenrouter; `auto_route` is not a dependency we take |
| 17 | `keyboard_dismiss_behavior` | |
| 18 | `textfield_with_multiple_stops` | the `TextField` escape, as a real case |
| 19 | `pull_to_refresh_in_sheet` | refresh at full extent, drag otherwise |
| 20 | `scrollable_pageview_sheet` | a `PageView` of lists — the nested-scrollable case |
| 21 | `offset_driven_animation` | needs the panel's position as a listenable, not just its detent |
| 22 | `decorations` | **out of scope by our own exclusion** — visual chrome. Recorded as excluded, not as failed. |

#### smooth_sheets — showcases (4)

| # | example | size | what it proves |
|:--|:--|:--|:--|
| 23 | `ai_playlist_generator` | 739 lines | |
| 24 | `airbnb_mobile_app` | 506 lines | |
| 25 | `safari` | 5 files, ~640 lines | the hardest: browser chrome, menus over a sheet |
| 26 | `todo_list` | 3 files, ~576 lines | an editor sheet with a keyboard |

#### stupid_simple_sheet — recipes and advanced (12)

Listed from `1.0.0-dev.2`, which is the newest published version — `0.9.1+1` is the latest
*stable* and ships a single `main.dart`, so the recipe set only exists on the prerelease.
Check `whynotmake-it/rivership` at HEAD before porting in case it has moved past dev.2.

| # | example | notes |
|:--|:--|:--|
| 27 | `recipes/basic_sheet` | |
| 28 | `recipes/content_sized` | `ContentDetent` |
| 29 | `recipes/content_sized_above_keyboard` | content sizing *and* the keyboard together |
| 30 | `recipes/snapping_recipe` | |
| 31 | `recipes/non_draggable` | a panel that only moves programmatically |
| 32 | `recipes/programmatic_control_recipe` | |
| 33 | `recipes/slide_vs_shrink_recipe` | our `PanelSizing.translate` vs `.resize`, side by side |
| 34 | `recipes/sticky_footer_recipe` | the same sticky-bar case as #7, from the other package |
| 35 | `advanced/custom_route_example` | |
| 36 | `advanced/dynamic_content_example` | content changing under a live panel — the correction protocol's whole reason |
| 37 | `advanced/share_sheet_example` | |
| 38 | `playground/playground_page` | every knob at once; a good smoke test for the config surface |
| — | `presets/cupertino_sheet_preset`, `presets/glass_sheet_preset` | **out of scope** — chrome |

**36 rows in scope, 3 excluded by our own scope line.** Two of them (#7 and #34) are the
same capability from two packages, which is worth keeping as two rows: if one ports and the
other does not, the difference is the finding.
