# zensheet — research notes

Working notes for a sheet package in this monorepo: what the platform does, what the
candidate Flutter packages actually implement, and what that means for the plan on record.
One further pass (a full behavioural specification turned into acceptance criteria) is
still running and will be folded in here.

Everything below cites the source it was read from. Paths:

| Short | Path |
|:--|:--|
| `SSS` | `~/.pub-cache/hosted/pub.dev/stupid_simple_sheet-1.0.0-dev.2` |
| `SDD` | `~/.pub-cache/hosted/pub.dev/scroll_drag_detector-0.1.0+2` |
| `MOTOR` | `~/.pub-cache/hosted/pub.dev/motor-1.1.0` |
| `SMOOTH` | `~/.pub-cache/hosted/pub.dev/smooth_sheets-1.0.3` |
| `NR` | `~/.pub-cache/hosted/pub.dev/navigator_resizable-3.0.3` |
| `SRC` | `<flutter-sdk>/packages/flutter/lib/src` (read at 3.44.9) |

---

## The standing plan, and why it does not survive the code

The plan of 2026-08-06 was: take `stupid_simple_sheet`'s core (spring motion via `motor`
+ `createSimulation`, velocity carry-over, frozen reference height, `RouteSnapshotMode`,
`clearBarrierImmediately`, `FlingSnapPhysics`, `scroll_drag_detector` handoff) and add
`navigator_resizable` for paged height animation, excluding visual chrome.

Three premises; two are wrong and the third is already built.

**1. The iOS feel is not in that core.** The one mechanic that matters is velocity carried
into the route's own dismissal simulation through `TransitionRoute.createSimulation`
(`SRC/widgets/routes.dart:272-278`, used at `SSS/lib/stupid_simple_sheet.dart:387-408`,
velocity stored at `:584`). That is about forty lines and a mixin. `RouteSnapshotMode` and
`clearBarrierImmediately` are polish worth copying. `FlingSnapPhysics` is *weaker* than the
`FrictionSnapPhysics` it replaced — see "Detents". `scroll_drag_detector` is the weakest
component in the set. **The core worth taking is an idea, not a codebase.**

**2. The geometry makes paging structurally unreachable.** `SSS` animates
`FractionalTranslation(translation: Offset(0, 1 - value))`
(`SSS/lib/src/sheet_dismissal_transition.dart:64-67`), which translates by a fraction of
its *own child's* height, and the drag reference is `context.size.height` of a box in the
same subtree (`:41`). So sheet height **is** content height by construction — which is
exactly why finger tracking is 1:1 and the open animation feels right, and exactly why
paging cannot be added:

- Paging needs the **frame** height to be the animated quantity, with content laid out
  inside it. Translation and resize are different render-object contracts.
- At `value == 1.0` the two coincide, so a **fully-open-only** paged sheet composes fine.
- Below that, a page height change from `H₁` to `H₂` moves the visible top edge by
  `v·(H₁ − H₂)` for reasons unrelated to the page transition.
- Throughout, an inner `ListView` gets a viewport of `H` while only `v·H` is on screen, so
  its extents and hit-testing below the fold are computed against off-screen space.
  **Detents and scrollable content are structurally incompatible in this model.**
- A detent of `0.5` means half the *content's* height, not half the screen. iOS detents
  resolve against available height. Different quantities.

The package knows: `SheetBackground` paints a screen-height of background *below* the
layout box via negative padding (`SSS/lib/src/sheet_background.dart:107-129`) purely so
over-drag reveals no gap, and `DismissalMode.shrink` is a second, frame-based geometry
bolted on beside the first (`SSS/lib/src/shrink_transition.dart:101-152`) — two child
layouts and an intrinsics walk per frame, with
`_illegallyComputeMinIntrinsicHeight` (`:154-163`) suppressing a framework assert and
getting `0.0` back for exactly the viewport children it is meant to guard
(`SRC/rendering/viewport.dart:705-725`).

**3. `smooth_sheets` already ships this combination.** It depends on `navigator_resizable`
and its `PagedSheet` runs the navigator-size and sheet-offset interpolations in lockstep,
swapping in a stepless snap grid for the transition and remembering each page's settled
offset (`SMOOTH/lib/src/paged_sheet.dart:405-464`, `:25-28`, `:284-293`). Building
"SSS core + navigator_resizable" re-derives that architecture from a base that cannot
express its geometry.

---

## Mechanics reference

### Motion

`SSS` derives springs from SwiftUI's `spring(duration:bounce:)` via
`SpringDescription.withDurationAndBounce` (`SRC/physics/spring_simulation.dart:70-82`).

| Motion | Source | mass | stiffness | damping | ζ |
|:--|:--|--:|--:|--:|--:|
| `CupertinoMotion.smooth()` — `SSS` route default, 500 ms | `SSS/lib/stupid_simple_sheet.dart:49` | 1.0 | 157.91 | 25.133 | 1.000 |
| `CupertinoMotion.smooth(350 ms)` — Cupertino/Glass variants | `SSS/lib/src/stupid_simple_cupertino_sheet.dart:18-21` | 1.0 | 322.27 | 35.904 | 1.000 |
| `smooth_sheets` default | `SMOOTH/lib/src/physics.dart:24-30` | 0.5 | 100.0 | 15.556 | 1.100 |
| Flutter `ScrollPhysics` default | `SRC/widgets/scroll_physics.dart:411-415` | 0.5 | 100.0 | 15.556 | 1.100 |
| Flutter `_kStandardSpring` — **measured off Apple's `CASpringAnimation`** | `SRC/cupertino/route.dart:1100-1106` | 1.0 | 522.35 | 45.710 | 1.000 |

The last row is the reference: Flutter read it out of Xcode and documents its natural
duration as 0.404 s (`SRC/cupertino/route.dart:1110-1116`) — and then uses it for popups
and dialogs, **not** for sheets.

**Velocity continuity is the differentiator, not the constants.**

- `SSS` seeds the pop simulation with the finger's exit velocity, so a flick and a slow
  release settle differently.
- `CupertinoSheetRoute` throws release velocity away: velocity only picks a *direction*
  (`_kMinFlingVelocity = 2.0` screen-heights/s, `SRC/cupertino/sheet.dart:78`), then
  settles with a fixed `animateTo(300ms, Curves.easeOut)` (`:1124-1143`). **There is no
  spring anywhere in `CupertinoSheetRoute`.** This is the largest fidelity gap in the SDK,
  and it is physics, not chrome.
- Material `BottomSheet` is closer — a real `fling` into a spring
  (`SRC/material/bottom_sheet.dart:302-304`) — but compares a height-normalised velocity
  against a raw `700.0` px/s threshold (`:301-302`).
- `smooth_sheets` seeds a `ScrollSpringSimulation` from drag velocity but zeroes it when
  it points away from the snap target (`SMOOTH/lib/src/physics.dart:114-118`), and its
  route transition is a 300 ms curve (`SMOOTH/lib/src/cupertino.dart:16-19`) — so a flung
  dismissal decays to a fixed curve at the route boundary, the same failure.

### Detents

`FlingSnapPhysics` takes the *next* detent in the fling direction above
`kMinFlingVelocity` (50 px/s), never skipping (`SSS/lib/src/snapping_point.dart:231-276`).
`smooth_sheets`' `MultiSnapGrid` is the same shape (`SMOOTH/lib/src/snap_grid.dart:92`).
Neither *projects*. UIKit's model is projection — `FrictionSimulation(0.135, …)`, derived
from `UIScrollView.decelerationRate` (`SRC/widgets/scroll_simulation.dart:50-57`), total
distance ≈ `0.4994 × velocity`. `SSS` ships that as the non-default `FrictionSnapPhysics`
(`snapping_point.dart:281-323`) and its changelog records that it *used to be* the
default. For three or more detents, projection is the behaviour to want back.

### Gesture arbitration

Three architectures, worst to best:

1. **Notification-driven** (`SSS` via `scroll_drag_detector`). A `ScrollNotification`
   listener flips a `ValueNotifier` that swaps in a `ScrollConfiguration` whose physics
   pins the list (`SDD/lib/scroll_drag_detector.dart:245-267`, `:511-555`). Structural
   problems: the swap only lands when `Scrollable.didChangeDependencies` re-reads the
   configuration (`SRC/widgets/scrollable.dart:669-674`), i.e. a frame late, *after* the
   position already moved; the leaked overscroll is then frozen for the rest of the
   gesture (`:549-553`); no `notification.depth` filter, so any nested vertical scrollable
   overwrites the state (`:274`); drag-end is deferred a frame (`:341-350`); scrollbars
   and glows are suppressed whenever the sheet is not fully open (`:456-473`). It also
   forces a restriction on the host: no custom `ScrollConfiguration` inside the sheet
   (`SSS/README.md:38`).
2. **`ScrollController` injection** (Flutter's `DraggableScrollableSheet`,
   `CupertinoSheetRoute`). Correct in principle; **silently does nothing if the app does
   not use the provided controller** (`SRC/cupertino/sheet.dart:604-609`).
3. **`ScrollPosition` interception** (`smooth_sheets`). `SheetScrollPosition` installs
   placeholder activities that never move pixels while one arbiter splits every delta
   (`SMOOTH/lib/src/scrollable.dart:950`, `:373-483`), and mid-fling it fuses the
   sheet-draggable range and the scrollable range into one synthetic axis handed to the
   scroll view's own physics (`:296-329`, `:644-667`). That is the correct answer to
   bidirectional velocity handoff: one simulation, two consumers.

**Nobody handles nested vertical scrollables.** `smooth_sheets` carries a standing TODO
(`SMOOTH/lib/src/scrollable.dart:146`); only `NestedScrollView` solves it in the SDK, with
a dedicated coordinator (`SRC/widgets/nested_scroll_view.dart:1056-1118`).

**Rule: intercept at `ScrollPosition`, never at notifications.** A notification is a report
that something already moved.

### Geometry

`smooth_sheets` measures offset as pixels from the viewport bottom to the sheet's top edge
(`SMOOTH/lib/src/model.dart:617-625`), lays content out with tight width and loose height
capped at available (`SMOOTH/lib/src/viewport.dart:899-906`), and takes min/max
exclusively from the snap grid. Crucially it has a **per-activity policy for content-size
change**, enforced by a `dryApplyNewLayout`/`applyNewLayout` contract with a consistency
assert (`model.dart:328-369`): a drag freezes pixels, idle re-resolves the snap target,
animations hand off to a duration-preserving settle, ballistic re-snaps within 150 ms.
That protocol is what makes keyboard, paging and dynamic content all work from one
mechanism, and a new package must own an equivalent.

### Keyboard

| | Reaction to `viewInsets.bottom` | Scroll preserved | Mid-drag change |
|:--|:--|:--|:--|
| `SSS` | a `SizedBox` spacer + `removeViewInsets` (`stupid_simple_sheet.dart:418-420`, `:486-489`) | not addressed | **breaks** |
| `smooth_sheets` | nothing automatic; caller-supplied padding shifts the detents (`model.dart:63`) | yes | pixels frozen |
| `CupertinoSheetRoute` | **nothing** — no `viewInsets` reference at all | — | — |
| Material `BottomSheet` | **nothing** | — | — |

The `SSS` failure is concrete: the keyboard spacer changes the content height `H`, which is
also the `FractionalTranslation` basis, while `_referenceHeight` stays frozen from drag
start (`stupid_simple_sheet.dart:160-163`) — so tracking desyncs and the sheet jumps.
Freezing the reference height is the right instinct for delta normalisation and does
nothing for the geometry, because the same number is both.

### Paged and nested

`navigator_resizable` **clips and aligns rather than re-laying out**: it passes parent
constraints through, lets the child Navigator overflow, sizes itself to the animated
preferred size and clips in `paint`/`hitTest` (`NR/lib/src/navigator_resizable.dart:331-356`).
Size interpolation runs off the route's own transition animation with
`Curves.easeInOutCubic` (`NR/lib/src/navigator_size_notifier.dart:120-132`); `_LazySizeTween`
re-reads start and end each tick, so a target page resizing mid-transition is picked up
live (`:188-198`), and gesture-driven transitions skip the curve to stay linear
(`:106-118`). **But a page height change outside a transition is applied instantly,
unanimated** (`:64-71`) — resizing during a drag is a jump.

Nested sheets: `SSS` coordinates nothing but snapshotting
(`stupid_simple_sheet.dart:297`, `:659-666`). `smooth_sheets` propagates real drag deltas
through `SheetGestureProxyMixin`, passing only the unconsumed remainder up the chain
(`SMOOTH/lib/src/drag.dart:334-359`) — but it is `@internal` with a TODO to expose it
(`gesture_proxy.dart:6`), and one `SheetViewport` per route is asserted
(`viewport.dart:278-290`), so sheet-in-sheet needs a new route.

---

## Interop, measured against zenrouter

zenrouter's hook is `PageCallback<T> = Page<void> Function(BuildContext, ObjectKey, Widget)`
(`packages/zenrouter/lib/src/internal/type.dart:120-125`), consumed by
`StackTransition.custom`. The Navigator's only requirement for a page-based entry is
`route.settings is Page` (`SRC/widgets/navigator.dart:3153`) — a `PopupRoute` qualifies.
**So the interop requirement reduces to: expose a `Page`.**

| | `Page` subclass | Own Navigator | Widget above `MaterialApp` | Flutter floor |
|:--|:--|:--|:--|:--|
| `SSS` | **no** — imperative `PopupRoute` only | no | no | declares `>=3.10.0`, **actually ≥3.32** |
| `smooth_sheets` modal | yes (`ModalSheetPage`) | no | no | 3.35.1 |
| `smooth_sheets` `PagedSheet` | yes, pages must be `PagedSheetPage` | **yes**, caller-supplied | no | 3.35.1 |
| `navigator_resizable` | routes need `ObservableRouteMixin` + a content boundary | yes | no | 3.35.1 |

Notes:

- **`SSS`'s declared SDK floor is wrong.** It uses `TransitionRoute.createSimulation`,
  `delegatedTransition`/`receivedTransition` and `RoundedSuperellipseBorder`, and depends
  on `motor`, which itself requires ≥3.32.
- **`SSS` has no declarative surface**, and its drag-dismiss calls `navigator?.pop()`
  imperatively (`stupid_simple_sheet.dart:624`) — which a declarative router has to
  reconcile against its own stack.
- `NavigatorResizable` requires non-tight, bounded constraints and asserts otherwise
  (`navigator_resizable.dart:307-329`).

### A live bug in this repo

`CupertinoSheetPage.createRoute` passes `builder:`
(`packages/zenrouter/lib/src/path/transition.dart:198`), which is deprecated after
v3.40.0 in favour of `scrollableBuilder` (`SRC/cupertino/sheet.dart:638-641`) — and
`scrollableBuilder` is the *only* path that gets scroll→sheet handoff. **zenrouter's
sheets currently have none.** Small, independent, worth fixing regardless of what happens
to zensheet.

---

## What the platform actually does — iOS 26 and 27

Sourced from Apple's own material (WWDC transcripts pulled raw, HIG via its DocC data
endpoint, availability read from each symbol's JSON). Numbers Apple does not publish are
marked as such rather than filled in from community measurement.

### iOS 26 is the inflection point, and it is SDK-linked

From **WWDC25 session 323, "Build a SwiftUI app with the new design"**:

> "On iOS 26, partial height sheets are inset by default with a Liquid Glass background."
> "At smaller heights, the bottom edges pull in, nesting in the curved edges of the display."
> "When transitioning to a full height sheet, the glass background gradually transitions,
> becoming opaque"

So a detent below full height renders *materially differently*: inset, glass, corners
nesting into the display's own curve; full height goes opaque and anchors to the edge.
The *Adopting Liquid Glass* overview adds that "sheets feature an increased corner radius"
— **Apple publishes no number for it anywhere I could find.**

Apple's instruction to developers is to *remove* customisation: "If you've used the
presentationBackground modifier to apply a custom background to your sheets, consider
removing that" (session 323), and "Audit the backgrounds of sheets and popovers"
(*Adopting Liquid Glass*).

**The change is gated on the SDK you link against, and the escape hatch expires.**
`UIDesignRequiresCompatibility` (Info.plist, iOS/iPadOS/macOS/tvOS 26.0): absent or `NO`
is the default for apps linking the latest SDKs; `YES` runs the app in a compatibility
mode. Apple marks it "Temporarily" and states: *"The system ignores this key when you
build for iOS 27 or later…"* So rebuilding against iOS 26 opts you in, and from iOS 27
there is no opting out.

Other iOS 26 sheet-adjacent changes:

- **Corners are concentric, not capsule.** "a button that is positioned at the bottom of a
  sheet should share the same corner center with the corners of the sheet" (session 323).
  APIs: `ConcentricRectangle` / `containerConcentric` in SwiftUI, `cornerConfiguration` in
  UIKit. Concentric shapes "calculate their radius by subtracting padding from the
  parent's" (session 356).
- **Glass reacts to focus.** "when focus shifts, like dragging a sheet upward, Liquid Glass
  subtly recedes, becoming more opaque" (session 356). Dimming remains the modality signal.
- **Sheets can morph out of the control that presented them** — the presenting toolbar item
  becomes the source of a zoom transition (session 323; UIKit: `preferredTransition = .zoom`).
- **Action sheets on iPhone are now anchored to their source**, as on iPad (session 284).
- **Avoid glass over glass**: Apple cites Maps removing its buttons when the sheet expands
  (session 284).
- **No sheet API deprecations in iOS 26.** Every topic on `UISheetPresentationController`
  was enumerated — `detents`, `largestUndimmedDetentIdentifier`, `prefersGrabberVisible`,
  `preferredCornerRadius`, `prefersEdgeAttachedInCompactHeight`,
  `widthFollowsPreferredContentSizeWhenEdgeAttached`,
  `prefersScrollingExpandsWhenScrolledToEdge` — none carry a deprecation marker.

### iOS 27 adds almost nothing for sheets

WWDC26 is public: 138 sessions, and the release is iOS 27. All 260 WWDC25 + WWDC26
transcripts were swept for sheet/detent/presentation terms. The only verified sheet API is
**`NavigationTransition.crossFade`** (iOS 27.0 **beta** at time of writing): "Specify this
transition in a sheet to have it appear by fading in over the content, as opposed to
moving upwards to cover content."

Adjacent, not sheets: `confirmationDialog`/`alert` gain the item-binding pattern sheets
already had; swipe actions work outside `List`. Session 269 says the 2027 releases refine
Liquid Glass "without having to change a single line of code" but does not name sheets.

**Not established:** any new detent API, any change to `presentationDetents`, any change to
corner-radius or background APIs. No evidence in 138 sessions or the SwiftUI release notes.

### HIG, and what Apple does *not* quantify

The HIG defines exactly two system detents — **large** ("the height of a fully expanded
sheet") and **medium** ("about half of the fully expanded height") — plus custom values.
**No pixel or point values appear anywhere on the page**, and corner radius is described
only qualitatively. Any specific number in circulation is community measurement.

Behavioural rules worth encoding as acceptance criteria:

- "Display only one sheet at a time from the main interface." If a sheet triggers another,
  close the first.
- "Support swiping to dismiss a sheet"; confirm with an action sheet if there are unsaved
  changes.
- Sheets are always modal on macOS/tvOS/visionOS/watchOS; iOS and iPadOS allow nonmodal
  (Apple's example: Notes' formatting sheet).
- Always pair Done with Cancel or Back; never show all three.
- A resizable sheet "expands when people scroll its contents or drag the grabber", and
  tapping the grabber cycles detents.

### Three source contradictions, recorded because they will bite

1. **Grabber guidance disagrees with itself.** HIG: "Include a grabber in a resizable
   sheet." WWDC21 session 10063: "A grabber often isn't necessary." SwiftUI's
   `presentationDragIndicator` defaults to `.automatic` — a third answer. Pick one and say
   why.
2. **`smallestUndimmedDetentIdentifier` does not exist.** The WWDC21 transcript names it;
   the shipped API is `largestUndimmedDetentIdentifier` ("The largest detent that doesn't
   dim the view underneath the sheet", iOS 15.0+). The session's *described behaviour*
   matches the shipped `largest` semantics — only the spoken name is stale. Any tool that
   scrapes that transcript will reproduce the wrong name.
3. **The "iOS 17" presentation modifiers are iOS 16.4.** `presentationBackground`,
   `presentationBackgroundInteraction`, `presentationContentInteraction`,
   `presentationCompactAdaptation` and `presentationCornerRadius` all shipped in March
   2023, before WWDC23 — corroborated by the June 2023 release notes not listing them.
   `presentationDetents` and `presentationDragIndicator` are iOS 16.0;
   `presentationSizing` is iOS 18.0.

One more API-shape note: in **UIKit**, undimmed implies interactive — removing the dimming
view is what lets touches through, and Apple frames it that way ("interact not only with
the content in the sheet but also with the content outside"). **SwiftUI split the two**
with `presentationBackgroundInteraction`. A package imitating iOS has to decide which
model it exposes.

### Method note for anyone repeating this

`developer.apple.com/design/human-interface-guidelines/*` is now a DocC SPA and returns an
empty shell to a plain fetch. The data endpoint has no `documentation/` segment:
`https://developer.apple.com/tutorials/data/design/human-interface-guidelines/sheets.json`.
Summarising fetchers were also observed corrupting a property name; raw fetch plus local
parsing is the reliable route.

---

## Where Flutter stands against that

**Flutter has not caught up and does not claim to.** Every geometry and timing constant in
`SRC/cupertino/sheet.dart` is annotated as eyeballed from **iOS 18.0** (`:29, 36, 42, 51,
58, 65, 73, 77, 81, 86, 1099, 1120`), the drag handle from 18.2 (`:704`). Searching all of
`SRC/` for iOS 26+ or Liquid Glass returns nothing; the highest version referenced anywhere
under `cupertino/` is 18.5. The squircle *has* landed (`RSuperellipse`/`ClipRSuperellipse`
are used broadly) — so: correct corner shape, iOS-18 corner radius, no glass, no morph.

`SSS` straddles both eras: its Cupertino variant is a literal fork of Flutter's iOS-18
constants ("measured… on an iPhone 16 Pro running iOS 18.0",
`cupertino_sheet_copy.dart:28-32`), while `StupidSimpleGlassSheetRoute` targets iOS 26
explicitly with a 36 px superellipse and a backdrop blur
(`stupid_simple_glass_sheet.dart:9`, `:55-58`). It is an iOS-26 skin over iOS-18 stack-back
geometry.

**Split to hold on to:**

*Physics — own it, it does not churn with iOS releases:* the spring family and the
duration/bounce parameterisation; velocity continuity from gesture into route dismissal;
the drag/extent split rule and bidirectional ballistic handoff; the *structure* of the
dismiss decision (velocity threshold → direction, else position threshold); rubber-band
friction and overscroll conventions; detent resolution and the content-resize protocol.

*Chrome — expect to revise per iOS release:* corner radius and the device-corner blend;
parent scale-back and slide; top gap; barrier dim; sheet-stacking offsets; drag-handle
dimensions; and the entire presence of a glass/blur/morph layer, which is new surface
area rather than a constant tweak.

One caveat: Flutter's *settle* is currently chrome-shaped (a fixed 300 ms curve) where it
should be physics-shaped, so "keep the physics, re-skin the chrome" inherits a fidelity
bug unless the settle is replaced.

---

## Defects found, per package

**`stupid_simple_sheet` 1.0.0-dev.2**

1. Translation-only geometry ⇒ detents incompatible with scrollable content. *Structural.*
2. `DismissalMode.shrink` does two child layouts + an intrinsics walk per frame
   (`shrink_transition.dart:111-139`).
3. `_illegallyComputeMinIntrinsicHeight` suppresses a framework assert and returns `0.0`
   for exactly the content type advertised (`:154-163`).
4. `ShrinkTransition.paint` does not clip despite its doc claiming it does (`:166-172` vs
   `:73-74`).
5. Drag-end resistance `1.0/(maxExtent + overshoot·R)` (`:600`) does not match drag-time
   `1.0/(1.0 + overshoot·R)` (`:557`), despite a comment claiming they are the same.
6. Overshoot resistance is not viewport-normalised (`:557`), so rubber-band feel varies
   with sheet height; `smooth_sheets` normalises to a fixed 120 px, and iOS is
   height-independent.
7. Keyboard inset changes mid-drag desync the frozen reference height (`:160-163`).
8. Declared Flutter floor is unsatisfiable.
9. No `Page` subclass; imperative `navigator?.pop()` from the drag handler (`:624`).
10. Inverted direction comments in `FlingSnapPhysics` (`snapping_point.dart:254-268`).

**`smooth_sheets` 1.0.3** — architecture is right, several real bugs:
`MultiSnapGrid._scanSnapOffsets` indexes the unsorted list and returns from the sorted one
(`snap_grid.dart:255-274`); `BouncingSheetPhysics` divides by `bounceExtent` unguarded in
one path and guarded in another (`physics.dart:221` vs `:260-262`); `maxVelocityLimit`
goes infinite or negative for documented-legal `resistance` values (`:273`); a listener
mismatch (`content_scaffold.dart:807-818`) and a rect-listener leak
(`viewport.dart:992-998`). Two API traps: `SheetScrollConfiguration.disabled` is the
*default* (`sheet.dart:64`), so a sheet silently ignores its list; and a default `Sheet`
has `minOffset == maxOffset`, i.e. is not draggable.

**Flutter SDK** — `CupertinoSheetRoute`: `enableDrag: false` does not disable scroll-driven
dismissal (`enabledCallback` assigned at `:749`, never invoked at `:1308`); a custom
`topGap` is ignored by the scroll path (`:1357`) *and* silently disables the parent
stack-back animation (`:819-821`).

---

## What a new package must own vs. depend on

**Own:**

1. A **frame-based geometry model** — the sheet is a laid-out box, content lays out inside
   it, translation is a special case rather than the primitive. Without this, detents and
   paging are both unreachable.
2. **`ScrollPosition`-level arbitration** — one arbiter splitting each delta, one fused
   ballistic axis.
3. A **content-resize correction protocol**, per activity.
4. **Velocity continuity across the route boundary**, via `createSimulation`.
5. A **`Page` subclass** as the primary API.

**Depend:**

- **`motor`** — a clean wrapper over `SpringSimulation` with SwiftUI's duration/bounce
  vocabulary. Pin your own constants; its internal defaults are inconsistent (500 vs
  550 ms).
- **`navigator_resizable`** — for page-to-page size interpolation, which is well built.
  It brings requirements: its own Navigator, a mixin on every route, a content boundary in
  every `buildPage`, non-tight bounded constraints.
- **`scroll_drag_detector`** — no.

---

## Suggested direction

1. **Now, independent of everything else:** fix `CupertinoSheetPage` to use
   `scrollableBuilder`. zenrouter's sheets have no scroll handoff today.
2. **Base `zensheet` on `smooth_sheets`' geometry, activity and scroll-interception
   model**, by dependency or adaptation. `ModalSheetPage` drops into
   `StackTransition.custom` unmodified; `PagedSheet.navigator` is caller-supplied, so
   zenrouter can hand it a nested Navigator built from a `StackPath`. Its defects are bugs
   in a correct architecture; `stupid_simple_sheet`'s is a correct implementation of an
   architecture that cannot reach the target.
3. **Port the two things `smooth_sheets` lacks**, both from `stupid_simple_sheet`:
   velocity continuity into the route's own dismissal simulation, and
   `RouteSnapshotMode`/`clearBarrierImmediately`.
4. **Keep the chrome layer separate from the physics layer and version it.** Every
   implementation examined bakes iOS-18 constants into the widgets that implement the
   physics, which is why none can be updated for iOS 26 without touching motion code.

---

## Open questions

- Whether `SSS`'s notification-based handoff is *perceptibly* a frame late, and whether the
  leaked overscroll is visible in practice. The code path is unambiguous; the magnitude
  needs a running app.
- `ShrinkTransition`'s per-frame double layout was not benchmarked — the cost is
  structural, the number is unknown.
- The iOS 26/27 behavioural specification (detents, background interaction, Apple Maps,
  sheet-over-sheet, keyboard, viewport arithmetic) is still being gathered and will be
  added to this document.
