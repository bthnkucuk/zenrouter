## 3.0.0

### ⚠️ Breaking Changes

- **Page keys are now identity-based** (via `zenrouter_core` 3.0.0). `NavigationStack`
  used to key each page with `ValueKey(route)`, which keys by **value**. Pushing the
  same route twice — a perfectly ordinary stack like `[/edit, /settings, /edit]` —
  produced two pages whose keys were `==`-equal.

  This never surfaced because the broken `Equatable.hashCode` (see `zenrouter_core`
  3.0.0) gave those keys different hash codes, so Flutter's
  `Navigator._debugCheckDuplicatedPageKeys` — which reserves keys in a `Set<Key>` —
  never saw the collision. With the hash contract repaired, the duplicate is real and
  must be fixed at the source.

  Pages are now keyed with `ObjectKey(route)`, which keys on the route **instance**.
  Since zenrouter's routes are live objects with one instance per stack entry, this
  gives every entry a distinct page identity.

- **`PageCallback` signature changed**: the `routeKey` parameter is now `ObjectKey`
  instead of `ValueKey<T>`.

  ```dart
  // Unaffected — the type is inferred:
  StackTransition(
    pageBuilder: (context, routeKey, child) => MaterialPage(key: routeKey, child: child),
    builder: (context) => const MyScreen(),
  );

  // Affected — an explicit annotation:
  // Before
  Page<void> buildPage(BuildContext context, ValueKey<AppRoute> routeKey, Widget child) => ...
  // After
  Page<void> buildPage(BuildContext context, ObjectKey routeKey, Widget child) => ...
  ```

  Every built-in transition (`.material`, `.cupertino`, `.sheet`, `.dialog`, `.none`)
  forwards the key unchanged, so they need no action.

- **`CoordinatorNavigatorObserver.observers` is deprecated in favour of
  `observersBuilder`.** The old contract was a single list applying to *every*
  `NavigationPath`, which Flutter forbids: `NavigatorState.initState` asserts
  `observer.navigator == null`, because an observer belongs to one navigator. A
  coordinator runs several at once — that is what layouts are — so sharing instances
  tripped that assert in debug and, in release, silently reassigned the observer so the
  navigator that had it stopped being reported on.

  There was no correct way to implement the old getter:

  | Implementation | Result |
  |---|---|
  | `final observers = [MyObserver()]` | asserts as soon as a second navigator exists |
  | `get observers => [MyObserver()]` | no assert, but a new instance on every read — the observers never accumulate anything |

  `observersBuilder` is called **once per navigator** and its result kept for that
  navigator's lifetime:

  ```dart
  @override
  NavigatorObserverListGetter get observersBuilder =>
      () => [LoggingNavigatorObserver(myLogSink)];
  ```

  Return a *fresh* observer per call — that is the point — and let them report into
  state you own, which is what survives. `observers` still works for one more major and
  now defaults to `const []`, so existing overrides keep running; they remain subject to
  the assert above.

#### One instance, one entry

Pushing the *same route instance* twice was never supported — one instance carries a
single path binding and a single result completer, so it cannot own two stack entries.
It used to fail as an opaque Flutter crash; `zenrouter_core` 3.0.0 now catches it in
`push` with a message that names the route. Push a new instance per entry:

```dart
final route = EditRoute();
path.push(route);
path.push(route);       // ❌ asserts, with an explanation

path.push(EditRoute());
path.push(EditRoute()); // ✅
```

Two *equal but distinct* instances — `[/edit, /settings, /edit]` — are supported, and
fixing them is what this release is about.

### Fixed

- **`replace` and `pushReplacement` no longer leave a back-navigable entry** (via
  `zenrouter_core` 3.0.0). On the web, signing in through a `replace` used to leave
  `/login` one back-press away. `CoordinatorRouteInformationProvider` now reports
  replacements as `neglect`.

  **This only works if the `Router` is given the coordinator's
  `routeInformationProvider`.** Handing `MaterialApp.router` a delegate and a parser
  alone makes Flutter build its own provider, and none of this runs. Pass the
  coordinator whole instead:

  ```dart
  MaterialApp.router(routerConfig: coordinator)
  ```

  In debug web builds the delegate now reports a `FlutterError` when it detects the
  wiring, rather than leaving the symptom to be found by pressing back. Every example
  in the repo has been switched over.

- **Disposing a path releases whatever is awaiting it.** `NavigationPath` and
  `IndexedStackPath` had no `dispose` of their own, so nothing completed the result of
  routes still on the stack. Every pending `await coordinator.push(...)` was left hanging
  for good — the code after the `await` never ran, and the awaiting frame kept its
  captured state alive. In tests it showed up as a hang.

  Both paths now complete each remaining route's result with `null` and clear its
  binding. The stack list itself is untouched: the path is being discarded whole, and no
  notification is emitted since listeners are being torn down rather than updated.

  Reachable wherever a coordinator outlives a pending result — a screen with a nested
  coordinator unmounting while a child awaits, a logout flow, test teardown.

- **A page refreshes when its route takes on new data** (via `zenrouter_core` 3.0.0).
  `NavigationStack` reused the `Page` of any route that stayed on the stack, and since
  that is the same widget instance Flutter short-circuited the subtree — so navigating
  to a route already on the stack updated the route and left the screen as it was.
  Only routes that actually changed are rebuilt, so nothing else pays for it.

- **`NavigationStack.declarative` applies stack changes atomically** (via
  `zenrouter_core` 3.0.0). Updating the `routes` list used to rebuild the path route by
  route, which completed the result of every route that survived the update. Showing a
  sheet and then letting an existing screen return a value threw
  `Bad state: Future already completed`. The update is now a single commit: surviving
  routes keep their identity, result and widget state, and the stack emits one
  notification instead of one per route.

- **`NavigationStack` now implements `onDidRemovePage`.** It was an empty callback, so
  when the `Navigator` removed a page on its own the path was synced indirectly, by the
  route taking itself off the stack with `==` — which removes the first equal entry.
  With `[/edit, /settings, /edit]` on the stack, closing the top `/edit` through
  `Navigator.of(context).pop()` removed the *first* `/edit` instead, leaving the path
  disagreeing with the screen about which route was on top.

  The page key identifies the exact route instance, so the removal is now targeted.
  Affects anything that pops outside the coordinator — a shared widget calling
  `Navigator.of(context).pop()`, an interactive swipe back, predictive back. The Android
  system back button was never affected; it goes through `popRoute` → `tryPop`.

- **Navigation on a path is serialized** (via `zenrouter_core` 3.0.0). A push arriving
  while an async pop guard was open — a deep link landing during a "discard unsaved
  changes?" dialog — used to be the route that got popped when the user confirmed,
  bypassing its own guard. Pushes whose redirects resolved at different speeds could
  also land out of call order. Both are fixed; see the `zenrouter_core` changelog for
  the details and for the two cases that deliberately bypass the queue.

- **A page leaving the stack keeps its exit transition when a dialog is closing
  above it.** Flutter's `DefaultTransitionDelegate` completes an exiting page instead of
  popping it whenever anything else is above the page — and *anything* includes a dialog
  the user just dismissed. Every pop guard produces exactly that: the dialog is answered,
  the guard returns `true`, and the page leaves while the dialog is still finishing its
  own exit. The screen vanished in one frame instead of sliding away.

  `NavigationStack` now uses `ZenTransitionDelegate`, which differs from the default in
  two places and matches it everywhere else:

  - A pageless route (`showDialog`, `showModalBottomSheet`) that has already been popped
    is on its way out by itself and no longer costs the page its transition.
  - An exiting page that is only covered by *non-opaque* exiting pages — a
    `StackTransition.dialog` or `.sheet` leaving at the same moment — still animates,
    since such a route never covered it.

  Two ordinary screens leaving together behave as before: only the top one animates,
  because the one below is not on screen to animate.

  A page that keeps its transition also reports its pop, which the completed-away case
  never did. So in those cases — a screen closed behind a guard's dialog, or under a
  dialog route leaving with it — the route's result future now completes, its path
  binding is cleared and `onDidPop` runs, where all three used to be skipped. An
  `await coordinator.push(...)` on such a screen used to hang for good.

- **`IndexedStackPathBuilder` lets go of the previous path's tabs.** Its children were
  built once and cached forever (`_children ??=`), with nothing to invalidate them, so a
  builder handed a different path kept rendering the old path's tabs — the new ones were
  never built. The cache is now keyed on the entries it was built from, compared by
  identity, so switching tabs still rebuilds nothing while a different set of tabs
  replaces the old one. Reachable only by using the widget directly; the default layout
  builder resolves the path from the coordinator, where it does not change.

- **A tab shows the data its route was handed, and the URL follows.** A tab list is
  fixed, so a tab that carries data is the *same* destination with different contents —
  `/search?q=shoes` is the search tab, not a second one. Navigating to it updated the
  route and then stopped there: two halves were missing. `IndexedStackPathBuilder` cached
  its children and never consulted `RouteTarget.needsRefresh`, which `NavigationStack`
  has honoured since the page-refresh fix; and `IndexedStackPath.activateRoute` returned
  without notifying when the tab it had just updated was already the active one, so the
  router never re-read the URI and the address bar kept the old query.

  Only updated tabs are rebuilt — the others are not touched — and a rebuilt tab keeps
  its widget state, its scroll position and its focus.

  Routes that expose their data through a `ValueNotifier` were already updating their own
  widgets, `RouteQueryParameters` among them; they now also rebuild in full when handed a
  fresh instance through `navigate`. `updateQueries` is unaffected and stays the targeted
  path.

- **Two tabs can hold the same `restorationId` without colliding.** A `NavigationPath`
  gets a restoration namespace from its `Navigator`; an indexed path has no navigator, so
  its tabs shared one — and `restorationId: 'field'` is exactly what a form widget shared
  between tabs would use. Each tab is now wrapped in a `RestorationScope` of its own,
  keyed by the route's restoration id.

  Tabs with *distinct* ids already restored, and still do; so does the active tab, by way
  of the path's `RestorablePath`. A tab whose path has no label cannot be keyed at all, so
  restoration is off for it rather than an error.

- **`IndexedStackPathBuilder.restorationId` is removed.** It was accepted and never read,
  and could not have been supplied anyway: the layout builder passed it as a fourth
  positional argument that `RouteLayoutBuilder` does not declare, so it was always `null`.
  The widget now derives what it needs from the coordinator. Delete the argument if you
  passed one.

- **Wrapping a listenable hands back the same wrapper.** `toListenableMixin` and
  `toFlutterListenable` built a fresh adapter per call, and both sit in getters read on
  every build — `canPopListenable` above all. To `ListenableBuilder` a new adapter is a
  different listenable, so it dropped its listener and re-registered it every frame. Each
  listenable now keeps one adapter for as long as it lives.

- **Restoration state is only re-serialised when it changed.** `CoordinatorRestorable`
  built a fresh map on every coordinator notification and assigned it, and assigning
  re-serialises everything — one `Uri` per route on every stack. Since the map was new each
  time, the framework's own equality check never caught it. Measured on an idle
  notification with 21 routes on the stack: **22 `toUri()` calls, now 1**, and it no longer
  grows with the depth of the navigation. A notification that does move the stacks saves as
  before.

- **A navigator handed a different path lets go of the first.** `didUpdateWidget` moved
  the listener that rebuilds pages but not the one that saves restoration state, so the
  old path kept it — and a listener is a bound method, so it held the `State` and
  everything under it for good. `dispose` then removed the survivor from the *new* path,
  where it was not. Only reachable by rendering a `NavigationStack` against a path that
  changes in place, which is what a per-instance layout path does.

### Added

- **`IndexedStackPath(lazy: true)` builds a tab when it is first opened.** Off by
  default, which is what an indexed stack normally means: every tab is built up front.
  Turning it on defers a tab's widgets, and whatever their `initState` does — analytics,
  prefetching, subscriptions — until the tab is first shown; from then on it is kept
  alive exactly as before. A behaviour change, hence opt-in: a tab that counted on doing
  work at startup will not. It is not a rendering optimisation — Flutter already skips
  paint, hit-testing and semantics for hidden tabs.

- **`IndexedStackPath(pauseHiddenTabs: true)` stops a tab ticking while it is off
  screen.** Off by default, matching Flutter: `IndexedStack` keeps every child ticking,
  so an animation in a tab the user cannot see goes on rebuilding it on every frame for
  as long as the app runs. That is usually the largest standing cost of a tab shell, and
  `lazy` does not address it — a tab visited once stays mounted and ticking.

  Separate from `lazy` because the two are independent and their risks differ. Two
  consequences follow from this one, and are why it is not the default: an animation in
  flight when the tab leaves freezes and resumes on return instead of finishing off
  screen, and `await controller.forward()` does not complete until the user comes back.
  It suits tabs whose animations are decoration, not tabs that drive logic from them.

  ```dart
  IndexedStackPath.createWith(
    coordinator: this,
    label: 'tabs',
    lazy: true,
    pauseHiddenTabs: true,
    [FeedTab(), ProfileTab(), SettingsTab()],
  );
  ```

- **A route can declare the stack it sits on** (via `zenrouter_core` 3.0.0). Opening
  `/products/42` from a link used to land on the detail alone, so the first back press
  left the app. A route now says what belongs underneath it:

  ```dart
  class ProductDetail extends AppRoute with RouteDeepLink {
    @override
    DeeplinkStrategy get deeplinkStrategy => DeeplinkStrategy.stack;

    @override
    List<RouteUri> deeplinkStack(Uri uri) => [ProductList(), this];
  }
  ```

  The URI pattern stays in `parseRouteFromUri` alone — the route knows its own context,
  so nothing is repeated. Routes that do not opt in behave exactly as before.

  A browser **back** press is still a URL-to-URL navigation and does not consult pop
  guards; only leaving through the app (`pop`, `tryPop`, system back) does. Coming
  back out of a screen the link established *is* an ordinary pop, so its guard runs.

- **A deep link no longer writes a second browser history entry.** `setNewRoutePath`
  returned before a `DeeplinkStrategy.stack` arrival had been applied, so the `Router`
  reported the URI the app had *not* moved to yet and the browser recorded an entry for
  a screen the user never saw. Walking back then took two presses per step. It is now
  awaited — only for that strategy, which settles once the stack is established; the
  others settle when the route is later popped and awaiting them would hang.

### Migration

Most projects need **no code changes**. See
[MIGRATION_GUIDE.md](https://github.com/definev/zenrouter/blob/main/packages/zenrouter/MIGRATION_GUIDE.md#300-equality-contract-repair)
for the full checklist.

## 2.3.0

### ⚠️ Breaking Changes

- **`GuardRule` contract renamed** (via `zenrouter_core` 2.2.0). The 2.1.0 / 2.2.0 methods are removed:

  | Removed | Replacement |
  |---------|-------------|
  | `canPop(route)` | `canPopRule(route)` / `canPopRuleWith(coordinator, route)` |
  | `canPopListenable(route)` | `canPopListenableRule(route)` / `canPopListenableRuleWith(coordinator, route)` |
  | `guard(coordinator, route)` | `guardRule(route)` / `guardRuleWith(coordinator, route)` |

  Use route-only methods when no coordinator is needed; override `*With` for dialogs / app state. Each `*With` defaults to its non-`With` counterpart.

  ```dart
  // Before
  class UnsavedChangesRule extends GuardRule<AppRoute> {
    @override
    bool canPop(AppRoute route) => !route.hasUnsavedChanges;

    @override
    FutureOr<bool?> guard(Coordinator c, AppRoute route) async =>
        showDiscardDialog(c.navigator.context);
  }

  // After
  class UnsavedChangesRule extends GuardRule<AppRoute> {
    @override
    bool canPopRule(AppRoute route) => !route.hasUnsavedChanges;

    @override
    FutureOr<bool?> guardRuleWith(Coordinator c, AppRoute route) async =>
        showDiscardDialog(c.navigator.context);
  }
  ```

### 🚀 New Features

- **`RouteGuard.canPopWith` / `canPopListenableWith`**: Coordinator-aware PopScope hints; `NavigationStack` prefers these when a coordinator is present.
- **`RouteGuardRule.popGuard`**: Runs the `guardRule` chain without a coordinator.

### 📖 Documentation

- Recipe / example / mixins API updated for the dual `guardRule` / `guardRuleWith` API.

## 2.2.0

### 🚀 New Features

#### `RouteGuardRule` — composable pop guards
- New `GuardRule` / `RouteGuardRule` API (via `zenrouter_core` 2.1.0) for reusable leave-confirmation chains — first non-null `bool` wins (`null` = continue).
- `RouteGuard.canPop` / `canPopListenable` drive Flutter `PopScope`; programmatic `pop` still always consults `popGuard` / `popGuardWith`.
- Flutter bridges: [`toListenableMixin()`](lib/src/internal/reactive.dart) / `toFlutterListenable()`; `NavigationStack` rebuilds `PopScope` via `ListenableBuilder` when a listenable is present.

### ⚠️ Breaking Changes

- **`CoordinatorCore.pop`**: Pops only the nearest eligible path (no longer multi-path in one call). Bumped `zenrouter_core` to `2.1.0`.
- **`RouteRedirect.resolve`**: Throws `StateError` on redirect type mismatch.

### 📖 Documentation

- **New Recipe**: [Composable Route Guard Rules](doc/recipes/route-guard-rules.md)
- **Example**: `example/lib/main_guard_rules.dart`
- **API**: [Mixins](doc/api/mixins.md) — guard rules section

## 2.1.1

- Bump `zenrouter_core` version to `2.0.3`

## 2.1.0

### 🚀 New Features

#### `CoordinatorView` — headless coordinator embed
- New [`CoordinatorView`](lib/src/coordinator/view.dart) widget renders a coordinator via `layoutBuilder` **without** Flutter's `Router`—for super apps, parallel panels, plugin surfaces, and other host-owned shells.
- Optional `initialUri` seeds navigation once when `coordinator.root.stack` is empty (ignored after the embed has stack state or on remount with the same coordinator).
- Supports sync and async `parseRouteFromUri` for the initial bootstrap.

#### `CoordinatorLayoutBuilder` mixin
- Extracted `layoutBuilder(BuildContext)` into [`CoordinatorLayoutBuilder`](lib/src/coordinator/layout.dart); [`CoordinatorLayout`](lib/src/coordinator/layout.dart) implements it so embed hosts can depend on layout rendering without `RouterConfig`.

### ⚠️ Breaking Changes

- **`layoutBuilder` moved to `CoordinatorLayout`**: Override `layoutBuilder` on your coordinator's `CoordinatorLayout` mixin (unchanged for typical `extends Coordinator` subclasses). It is no longer declared on the `Coordinator` class body.
- **`RouteLayoutBuilder` signature**: The first parameter is now `CoordinatorCore` instead of `Coordinator`. Update custom `defineLayoutBuilder` / `kDefaultLayoutBuilderTable` callbacks accordingly (cast to `Coordinator` when you need Flutter-specific APIs).
- **`RouteLayout.buildRoot`**: Now accepts `CoordinatorLayout` instead of `Coordinator`. Call sites that passed a bare `CoordinatorCore` must use a type that provides `getLayoutBuilder` / `root`.

### 📖 Documentation

- **New Guide**: [CoordinatorView](doc/guides/coordinator-view.md) — embed patterns, `initialUri` semantics, pitfalls vs `MaterialApp.router`
- **API**: [Coordinator API](doc/api/coordinator.md) — `CoordinatorView` section and dual quick-start
- **Roadmap**: Embedded / multi-surface learning path in [DOCUMENTATION_ROADMAP](doc/DOCUMENTATION_ROADMAP.md)

## 2.0.3
- **Fix**: `CoordinatorModular.getModule` now correctly resolves the coordinator itself — `runtimeType: this` is registered in `_allModules`, enabling `getModule<MyCoordinator>()` to work at any level of the hierarchy. (Bumped `zenrouter_core` to 2.0.2)

## 2.0.2
- **Fix**: Fix `CoordinatorModular` edgecase cascading dispose and prevent duplicate definitions. (Bumped `zenrouter_core` to 2.0.1)

## 2.0.1
- **Fix**: Revert `hasEmptyPath` back to `pathSegments.isEmpty` in `resolveInitialUri` for correct path empty checks.
- **Refactor**: Remove redundant `initialRouteInformation` parameter from `CoordinatorRouteInformationProvider` since fallback defaults and resolution logic is robust now.

## 2.0.0

🎉 **Major Release - Core Architecture & Layouts**

### 🚀 New Features

- **`zenrouter_core` Package**: Extracted all platform-independent core routing types (`RouteTarget`, `CoordinatorCore`, `StackPath`, and route mixins) into a new dedicated package.
- **Composable Redirects**: You can use `RouteRedirectRule` as `RouteRedirect` to allow composable, testable redirect logic via multiple rules (e.g., `StopRedirect`, `ContinueRedirect`, `RedirectTo`).
- **Route Identity updates**: Introduced `RouteUri` abstract class (and `RouteUnique`) to centralize URI-based identity for coordinator-managed routes.

### ⚠️ Breaking Changes

- **Layout Binding Refactoring**: The global `RouteLayout.defineLayout` has been removed. You must now bind layouts to paths using the `StackPath.bindLayout()` cascade syntax (e.g., `NavigationPath.createWith(...)..bindLayout(HomeLayout.new)`), or use `defineLayoutParent()` / `defineLayoutBuilder()` inside the coordinator.
- **Core Mixins Relocated**: Core routing types have been consolidated under `zenrouter_core`. The main package still exports them, but any explicit deep imports to old paths must be updated.
- **RouteLayout.definePath Deprecated**: Deprecated `RouteLayout.definePath` in favor of `coordinator.defineLayoutBuilder`.

### 📖 Documentation

- **Architecture Overview**: Completely redesigned READMEs to highlight the layered architecture and paradigm decisions.
- **API Reference**: Rewrote coordinator, mixins, and navigation paths API references from source.

## 1.2.0

### 🐞 Fixes
- **Fix**: Regression error when using `RouteRedirectRule` inside `IndexedStackPath` (Thanks to @obenkucuk)

### 🚀 New Features

#### Coordinator as RouteModule — Nested Coordinators
- `Coordinator` now implements `RouteModule<T>`, enabling any coordinator to be nested inside a `CoordinatorModular` by overriding the `coordinator` getter.
- Unlocks **route versioning** (V1/V2 side by side), multi-team modular architectures, and deeply nested coordinator hierarchies.
- Auto-detected `isRouteModule` flag controls root path creation vs parent inheritance.
- See [Guide](doc/guides/coordinator-as-module.md) & `example/lib/main_coordinator_module.dart`

### ⚠️ Breaking Changes

- **`Coordinator.parseRouteFromUri`** signature changed from `FutureOr<T>` to `FutureOr<T?>`. Child coordinators return `null` for unrecognized URIs; standalone coordinators are guarded by assertions.
- **`CoordinatorModular.parseRouteFromUri`** returns `null` instead of `notFoundRoute` when the coordinator is itself a nested module.

### 📖 Documentation

- **New Guide**: [Coordinator as RouteModule](doc/guides/coordinator-as-module.md)
- **New Recipe**: [Route Versioning](doc/recipes/route-versioning.md)

## 1.1.0

- BREAKING CHANGE: Remove `coordinator` from `defineModules`, use `this` getter instead.
- Feat: Enforce `getModule` method return exact type.

## 1.0.0

🎉 **Major Release - Production Ready**

### 🚀 New Features

#### CoordinatorModular - Modular Route Management
- Split route management across independent modules by domain/feature
- `CoordinatorModular` mixin + `RouteModule` base class
- Perfect for large apps with team collaboration
- See [Guide](doc/guides/coordinator-modular.md) & `example/lib/main_modular.dart`

```dart
class AppCoordinator extends Coordinator<AppRoute>
    with CoordinatorModular<AppRoute> {
  @override
  Set<RouteModule<AppRoute>> defineModules() => {
    AuthModule(this),
    ShopModule(this),
  };
}
```

#### RouteRedirectRule - Composable Redirect Logic
- Reusable, chainable redirect rules (auth → feature flags → logging)
- `RedirectResult` sealed class with `Stop`/`Continue`/`RedirectTo` variants
- Async support for API calls, database queries

```dart
class ProtectedRoute extends AppRoute
    with RouteRedirect, RouteRedirectRule {
  @override
  List<RedirectRule> get redirectRules => [
    AuthenticationRule(),
    PermissionRule(permission: 'admin'),
  ];
}
```

### ⚠️ Breaking Changes

**Removed deprecated APIs:**
- `RouteLayout.buildPrimitivePath` → Use `RouteLayout.buildPath`
- `RouteLayout.layoutBuilderTable` → Use `RouteLayout.buildPath`
- `RouteLayout.navigationPath`/`indexedStackPath` → Use `NavigationPath.key`/`IndexedStackPath.key`
- `routerDelegateWithInitialRoute` → Use `RouteRedirect` in `IndexRoute`

See [Migration Guide](MIGRATION_GUIDE.md) for details.

### 📦 What's Included

- ✅ Stable API surface
- ✅ Full test coverage (48 new tests: 33 modular + 15 redirect rule)
- ✅ Comprehensive documentation with guides

---

## 0.4.20

* **Fix**: back gesture failed in android

## 0.4.19

* **Fix**: Blank screen when using `Coordinator` as `routerConfig` (due to unset `routerInformationProvider`).
* **Feat**: Added `initialRoutePath` property to `Coordinator`.
* **Feat**: Added `NavigatorObserverListGetter` typedef for passing external observers. ([View Guide](https://github.com/definev/zenrouter/blob/main/packages/zenrouter/doc/guides/navigator-observers.md#passing-observers-from-outside))

## 0.4.18
- **Feat**: Add `pushReplacement` method in `StackMutatable`.
- **Feat**: `Coordinator` now implements `RouterConfig` so you can use it with `MaterialApp.router` more easily.
  - ```dart
    MaterialApp.router(
      // New way
      routerConfig: coordinator,
      // Old way
      routerDelegate: coordinator.routerDelegate,
      routeInformationParser: coordinator.routeInformationParser,
    );
    ```
- **Deprecate**: `routerDelegateWithInitialRoute` is deprecated, you can simulate the same behavior by using `RouteRedirect` in `IndexRoute`.

## 0.4.17
- ZenRouter officially achieved 100% test coverage 🚀
- **Docs**: Added migration guides from other packages (go_router, auto_route, and Navigator 1.0/2.0)
- **Docs**: Added recipes for common use cases
- **Docs**: Added quick links section to make the docs easier to navigate

## 0.4.16
- **Fix**: Future already completed bug when pushing the same route with `pushOrMoveToTop`.

## 0.4.15
- **Feat**: Add `onUpdate` method to `RouteTarget` for handling in-place route updates when navigating to the same route with different state.
- **Feat**: Add `bindLayout` method to `StackPath` as a convenient alternative for layout registration. (See [RouteLayout Guide](doc/guides/route-layout.md))

## 0.4.14
- **Breaking Change**: Don't allow `redirect` to return null anymore since it doesn't do anything.
- **Feat**: Add `mustCallSuper` to `paths` getter (Thanks @mrgnhnt96)
- **Feat**: Add `discard` parameter to `remove` method for controlling discarding behavior.
- **Fix**: Memory leak when pushing `RouteQueryParameters` in `IndexedStackPath`.
- **Fix**: Memory leak when discard route in `RouteRedirect`.

## 0.4.13
- **Fix**: Ensure `navigate` method is compatible with `RouteRedirect`.

## 0.4.12
- **Feat**: Introduce new `StackNavigatable` mixin for `StackPath` to handle custom logic when receiving a `navigate` command. (Back/Forward button on the browser)
- **Fix**: `navigate` clear all history that occurred when pushing a custom layout.

## 0.4.11
- **Feat**: Expose `stackPath` in `RouteTarget` and expose `protected` method for developer create custom `stackPath`.
- **Feat**: Add `onDiscard` to handle discarding phase in `RouteTarget`.

## 0.4.10
- **Chore**: Fix analyzer warnings

## 0.4.9
- **Chore**: Standardize `serialize` and `deserialize` for supported `RouteTarget` type

## 0.4.8
- **Feat**: Introduce new state restoration with `RouteRestoration` mixin. Support state restoration by default if `restorationScopeId` is provided in `MaterialApp.router` and using `Coordinator` pattern.
- **Fix**: Resolve bug in `recover` method where `RouteRedirect` was ignored.

## 0.4.7
- **Docs**: Update README

## 0.4.6
- **Docs**: Update README and add screenshots

## 0.4.5
- **Feat**: Add `RouteQueryParameters` mixin for targeted query parameter updates using `ValueNotifier`.
- **Fix**: Ensure `path` is set for `RouteTarget` when initial `IndexedStackPath`.
- **Fix**: Ensure `layout` is resolve correct if they under deeper stack.
- **Refactor**: Refactor folder structure and test folder structure to be more organized.

## 0.4.4
- **Feat**: New ZenRoute Logo!
- **Docs**: Improve document and update outdate example

## 0.4.3
- **Feat**: Add `CoordinatorNavigatorObserver` mixin to provide a list of observers for the coordinator's navigator.
- **Breaking Change**: Complete redesign [RouteLayout] builder to be more flexible and powerful.
  - Deprecate static method `RouteLayout.buildPrimitivePath` and use `buildPath` function instead.
  - Add ability to define new [StackPath] using `RouteLayout.definePath`. You can create custom behavior path builder. (Eg: RecoverableHistoryStack like unrouter)

## 0.4.2
- **Feat**: Add `transitionStrategy` to `Coordinator` for default stack transition setup
- **Fix**: Ensure when [Navigator.pop] called sync new stack with [NavigationPath]

## 0.4.1
- **Fix**: Ensure [Coordinator.routeDelegate] initialize once
- **Improvement**: Add [IndexedStackPathBuilder] for improve performance for rendering [IndexedStackPath]

## 0.4.0
- **Breaking Change**: Deprecated default constructors for `NavigationPath` and `IndexedStackPath`. Use `NavigationPath.create`/`createWith` and `IndexedStackPath.create`/`createWith` instead.
- **Breaking Change**: Introduced `internalProps` to `RouteTarget` for better deep equality and hash code generation.
- **Feat**: Added `popGuardWith` to `RouteGuard` and `redirectWith` to `RouteRedirect` for coordinator-aware mixin logic.
- **Feat**: Added strict path-coordinator binding support via `createWith` factories.
- **Docs**: Added comprehensive [Migration Guide](MIGRATION_GUIDE.md).
- **Feat**: Added `routerDelegateWithInitalRoute` to `Coordinator`.
- **Feat**: Enhanced `setInitialRoutePath` to correctly handle initial routes vs deep links.

## 0.3.2
- Add `navigate` function: A smarter alternative to `push` that handles browser history restoration by popping to existing routes instead of duplicating them.

## 0.3.1
- Allow `parseRouteFromUri` to return `Future` for implementing deferred import/async route parsing

## 0.3.0
- Breaking change: Change return of `Coordinator.push()` from `Future<dynamic>` to `Future<T?>`
- Fix `NavigationStack` rerender page everytime `path` updated. Resolve [#10](https://github.com/definev/zenrouter/issues/10).
- Feat: Add `recover` function

## 0.2.3
- Update `activePathIndex` to `activeIndex` in `IndexedStackPath`
- Update document for detailed, hand-written example of Coordinator pattern

## 0.2.2
- Expose pop result in Coordinator
- **Fix memory leak**: Complete route result futures when routes are removed via `pushOrMoveToTop`
- **Fix memory leak**: Complete intermediate route futures during `RouteRedirect.resolve` chain

## 0.2.1
- Standardize how to access primitive path layout builder
    - Define using `definePrimitivePath`
    - Build using `buildPrimitivePath`

## 0.2.0
- BREAKING: Rename `activeHostPaths` to `activeLayoutPaths` to reflect correct concept.

## 0.1.2
- Update homepage link

## 0.1.1
- Fix broken document link by update it to github link

## 0.1.1
- Fix broken document link

## 0.1.0

- Initial release of ZenRouter.
- Unified Navigator 1.0 and 2.0 support.
- Coordinator pattern for centralized navigation logic.
- Support for both Declarative and Imperative navigation paradigms.
- Route mixins: `RouteGuard`, `RouteRedirect`, `RouteDeepLink`.
- Optimized Myers diff algorithm for efficient stack updates.
- Type-safe routing with `RouteUnique`.
