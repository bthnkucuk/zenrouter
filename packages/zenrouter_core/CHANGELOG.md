## 3.0.0

### ⚠️ Breaking Changes

- **`Equatable.hashCode` no longer mixes in `internalProps`.** The previous
  implementation was `mapPropsToHashCode(internalProps) ^ mapPropsToHashCode(props)`,
  and `RouteTarget.internalProps` returned `[runtimeType, _path, _onResult]`. Because
  `_onResult` is a fresh `Completer` per instance, two routes that compared **equal**
  always produced **different** hash codes — a violation of Dart's
  `a == b ⇒ a.hashCode == b.hashCode` contract.

  Any code that put routes in a `Set` or used them as `Map` keys was silently broken:
  `set.contains(equalRoute)` returned `false`, and two `==`-equal routes landed in
  separate buckets.

  ```dart
  final a = ProductRoute('42');
  final b = ProductRoute('42');

  a == b;                  // true (before and after)
  a.hashCode == b.hashCode; // before: false ❌   after: true ✅
  {a}.contains(b);          // before: false ❌   after: true ✅
  ```

  `hashCode` is now derived from `runtimeType` and `props` only — exactly the inputs
  `==` uses.

- **`Equatable.internalProps` is removed.** It existed solely to feed `hashCode`, so it
  no longer has a purpose. It was documented as "**Do not override**", so no override
  should exist in user code. If you did override it, delete the override and make sure
  every value that affects identity is listed in `props` instead.

- **`RouteTarget.deepEquals` is now an identity check** (`identical(this, other)`)
  instead of `hashCode == other.hashCode`. The old form only behaved like an identity
  check *because* of the broken hash, and it carried a real collision risk. The
  framework uses this to distinguish "the route already on the stack" from "a fresh,
  redundant instance that must be discarded", which is exactly identity.

  Behaviour changes only for `RouteLayoutParent` / `RouteLayout` routes, which override
  `==` / `hashCode` by layout key: two distinct-but-equal layout instances now compare
  `false`, so the redundant instance is correctly discarded and its stack-path binding
  cleared.

### Added

- **`push` now asserts that the route instance is not already on the path.** A
  `RouteTarget` owns one path binding and one result completer, so it maps to exactly one
  stack entry. Pushing the same instance twice made both `push` futures share a
  completer and unbound the surviving entry — it previously surfaced as an opaque
  `_dependents.isEmpty` crash from Flutter. It now fails immediately with a message that
  names the route and the fix. Debug-only; two *equal but distinct* instances remain
  fully supported.

- **`navigate` and `pushOrMoveToTop` now assert that `props` identifies the
  destination.** Both find an existing entry with `indexOf`, which compares by value —
  that is, by `props`. When `props` omits a field the route is identified by, two
  different destinations compare equal and the match lands on the wrong one, silently:

  ```
  navigate matched a route with a different URI.
    asked for  /order/8123
    matched    /order/5500
  ```

  A deep link to order 8123 left you on 5500, and the URL was corrected back to match.
  The mirror is caught too: no entry compares equal while one on the stack carries the
  very same URI, which means `props` holds per-instance state — a completer, a callback,
  a timestamp — and a route that should have moved to the top is pushed again.

  Only the **path** is compared for a match. Query strings are excluded on purpose:
  `RouteQueryParameters` exists so a route keeps its identity while its queries change,
  and such a match is updated in place rather than being a mistake. The mirror check
  compares the full URI, since two destinations that differ only by query are legitimately
  distinct routes.

  Debug-only, stripped in release, no API change. **It can fire on upgrade** — if it
  does, it has found a real bug; see the migration guide.

### Fixed

- **Stack mutations are serialized.** Every mutation on a `StackMutatable` awaits
  something before it touches the stack — `RouteRedirect.resolve` on the push side,
  `RouteGuard.popGuard` on the pop side. A mutation arriving during one of those gaps
  used to observe, and corrupt, a stack that was mid-flight. Two concrete failures:

  - **A push landing during an async pop guard stole the pop.** With `[A, B]` on the
    stack and `B`'s guard showing a "discard unsaved changes?" dialog, a route `C`
    pushed by a deep link while the dialog was open would be the one removed when the
    user confirmed — leaving `B` in place and never consulting `C`'s own guard, even if
    that guard refused every pop.

  - **Pushes could land out of order.** `push(profile)` followed by `push(settings)`
    ended up with `profile` on top whenever `profile`'s redirect (an auth check, say)
    took longer than `settings`'s.

  Mutations now run one at a time, in call order. Two cases deliberately bypass the
  queue so timing is unchanged where there is nothing to protect: an unguarded `pop`
  (no guard means no await gap, so bursts of fire-and-forget pops still apply
  synchronously) and the first mutation when nothing else is in flight.

  `push` enqueues only its mutating region — never its result future, which settles on
  pop and would otherwise hold the queue for as long as the route is on screen.

- **A route removed by the `Navigator` no longer takes the wrong entry off the path.**
  `RouteTarget.onDidPop` used to remove the route from its path with `==`, which removes
  the *first* equal entry. On a stack that legitimately repeats a route — now that equal
  routes are supported at all — that was the wrong one:

  ```
  before                     [home, editA, settings, editB]
  editB closes itself via Navigator.pop()
  after (broken)             [home, settings, editB]
  ```

  `editA` left the path while `editB` stayed on it with its binding cleared, so the
  stack disagreed with the screen about which route was on top. Reachable from anything
  that pops outside the coordinator: a shared widget calling `Navigator.of(context).pop()`,
  an interactive swipe back, predictive back. (The Android system back button was never
  affected — it routes through `popRoute` → `tryPop`, an ordinary programmatic pop.)

  `onDidPop` now only completes the result and clears the binding. Which entry left is
  reported by `Navigator.onDidRemovePage`, whose page key names the exact route instance.

- **A declarative stack update no longer completes the result of routes that survive
  it.** `applyDiff` rebuilt the path as `reset()` plus a `push` per route. `reset` calls
  `clear`, which completes the result completer of *every* route on the stack — the ones
  carried over included. Those routes then went back on the stack already completed, so
  closing one with a value later threw:

  ```
  Bad state: Future already completed
  ```

  The trigger is ordinary: any update that inserts a route — a plain append is enough,
  since the insert-only branch rebuilt the path too — followed by a surviving route
  returning a value. `applyDiff` now computes the target stack and commits it in one
  pass, so carried-over routes keep their identity, their completer and their widget
  state, and one notification is emitted instead of one per route.

  This affects the declarative paradigm only; `applyDiff` has no other caller.

- **A redirect now decides once per navigation.** Every layer resolved
  independently: the coordinator resolved to work out the layout, handed the target
  to a path, which resolved again, and `navigate` resolved once more on its way to a
  push. Measured invocations of a single route's `redirectWith`:

  ```
                            before   after
    coordinator.push          2x      1x
    coordinator.navigate      3x      1x
    pushOrMoveToTop           2x      1x
    coordinator.replace       2x      1x
  ```

  This is not only wasted work — an auth check or service call in a redirect ran
  several times per navigation. There are `await`s between those layers, so whatever
  the redirect consults can move in between and the layers can reach different
  answers for one navigation. A route now carries the fact that its chain is settled.

  Decisions are not cached across navigations: a later navigation with a fresh route
  instance takes the decision again, so a redirect that changes its mind — a session
  expiring — still works. A test pins that.

- **A route updated in place now reaches the screen.** `navigate` and
  `pushOrMoveToTop` hand an existing entry the incoming route through
  [`RouteTarget.onUpdate`] rather than pushing a duplicate — but the page was built
  once and reused, so the new data never showed. `onUpdate` looked like it worked:
  the route held the new values while the screen kept the old ones.

  `onUpdate` now marks the route as needing a rebuild, and the renderer refreshes
  exactly those routes. Untouched entries keep their page, so an unrelated push costs
  nothing extra — measured at 10 `build` calls for ten push/pop cycles on a six-deep
  stack, the same as before. Page identity is unaffected, so a refreshed page keeps
  its widget state.

  Overrides of `onUpdate` must call `super.onUpdate(newRoute)` — that is what marks
  the route. It was already `@mustCallSuper`. Being handed *itself* marks nothing,
  since nothing was transferred; `onUpdate` still runs, so anything it derives is
  still refreshed.

- **`pushOrMoveToTop` notifies when it updates the route already on top.** It called
  `onUpdate` and returned silently, so nothing told the UI. Handing in the very same
  instance is still a no-op and stays silent.

- **A replacement no longer adds a browser history entry.** `replace` and
  `pushReplacement` discard the stack they replace, but every URI change was
  reported to the browser as a new entry, so the back button walked straight back
  into screens the app had thrown away — the login page you just signed in from,
  each step of an onboarding flow. `pushReplacement` was worse than it looks: being
  a pop followed by a push, it reported twice, leaving a transient state in the
  history the user never saw.

  Each commit now records whether it replaces or advances, and the coordinator's
  route information provider turns that into `RouteInformationReportingType.neglect`
  at report time. Reading the intent at report time is the whole trick — the report
  runs in a post-frame callback, so a synchronous `Router.neglect` around the
  navigation call would have returned long before.

  Affects the web only; elsewhere the platform back button unwinds the `Navigator`
  and no history stack is involved.

### Added — API

- **`RouteTarget.redirectResolved` / `markRedirectResolved`** record that
  `RouteRedirect.resolve` has settled a route's redirect chain, so the layers of one
  navigation do not each re-decide it. Framework-managed.

- **`RouteTarget.needsRefresh` / `didRefresh`** let a renderer tell a route that
  merely stayed on the stack from one that stayed *and* changed, so only the latter
  pays for a rebuild. Set by `onUpdate`, cleared by the renderer.

- **`StackMutatable.removeIdentical`** removes a specific live entry, matching on
  identity instead of `==`. Use it over `remove` whenever the caller knows which
  instance left and the stack may hold equal routes. It is a no-op if the route is
  already gone, so it is safe to call twice.

- **`CoordinatorCore.replacesHistoryEntry`** reports whether the most recent commit
  should overwrite the current browser history entry. Framework-managed; assign only
  from a path committing a mutation.

- **`StackMutatable.activateReplacing`** activates a route as the only entry and
  marks the commit as a replacement. Used by `replace`, including for the layouts it
  activates on the way — those commits are not awaited, so leaving them unmarked let
  them overwrite the intent after the fact.

- **`StackMutatable.applyStack`** replaces the whole stack in one commit, carrying over
  the entries that appear in the target and discarding the rest. It is the primitive for
  declarative updates, where the caller already knows the target stack; guards are not
  consulted, since the caller declared it.

### Migration

Most projects need **no code changes**. See
[MIGRATION_GUIDE.md](https://github.com/definev/zenrouter/blob/main/packages/zenrouter/MIGRATION_GUIDE.md#300-equality-contract-repair)
for the full checklist.

## 2.2.0

### Breaking Changes

- **`GuardRule` contract renamed** for coordinator-optional use. The 2.1.0 methods are removed:

  | Removed (2.1.0) | Replacement |
  |-----------------|-------------|
  | `canPop(route)` | `canPopRule(route)` / `canPopRuleWith(coordinator, route)` |
  | `canPopListenable(route)` | `canPopListenableRule(route)` / `canPopListenableRuleWith(coordinator, route)` |
  | `guard(coordinator, route)` | `guardRule(route)` / `guardRuleWith(coordinator, route)` |

  Migration:

  ```dart
  // Before (2.1.0)
  class UnsavedChangesRule extends GuardRule<AppRoute> {
    @override
    bool canPop(AppRoute route) => !route.hasUnsavedChanges;

    @override
    FutureOr<bool?> guard(CoordinatorCore c, AppRoute route) async { /* ... */ }
  }

  // After (2.2.0) — route-only
  class UnsavedChangesRule extends GuardRule<AppRoute> {
    @override
    bool canPopRule(AppRoute route) => !route.hasUnsavedChanges;

    @override
    FutureOr<bool?> guardRule(AppRoute route) async { /* ... */ }
  }

  // After (2.2.0) — needs coordinator (dialogs, app state)
  class UnsavedChangesRule extends GuardRule<AppRoute> {
    @override
    bool canPopRule(AppRoute route) => !route.hasUnsavedChanges;

    @override
    FutureOr<bool?> guardRuleWith(CoordinatorCore c, AppRoute route) async { /* ... */ }
  }
  ```

  Each `*With` method defaults to its non-`With` counterpart. `guardRule` defaults to `null` (continue chain).

### New Features

- **`RouteGuard.canPopWith` / `canPopListenableWith`**: Coordinator-aware PopScope hints (default to `canPop` / `canPopListenable`).
- **`RouteGuardRule.popGuard`**: Now runs the `guardRule` chain (no coordinator), matching `popGuardWith` → `guardRuleWith`.

## 2.1.0

### New Features

- **`GuardRule` / `RouteGuardRule`**: Composable pop-guard chains (first non-null `bool` wins), mirroring `RedirectRule` / `RouteRedirectRule`.
- **`RouteGuard.canPop` / `canPopListenable`**: Sync PopScope hint plus optional `ListenableMixin` invalidation when leave-safety changes.
- **`ListenableMixin`**: Subscribe-only reactive surface (with `ListenableMixin.merge`); `ListenableObject` now implements it.

### Breaking Changes

- **`CoordinatorCore.pop`**: Pops only the nearest eligible stack path. Nested shells are no longer popped together with child stacks in a single call.
- **`RouteRedirect.resolve`**: Throws `StateError` when a redirect returns a different route type (previously silently ignored).

## 2.0.3

- chore: make `RedirectRule` can be const

## 2.0.2

- Fix `CoordinatorModular.getModule` now correctly resolves the coordinator itself by registering `runtimeType: this` in `_allModules`, enabling `getModule<MyCoordinator>()` to work at any level of the hierarchy.

## 2.0.1

- Fix `CoordinatorModular` edge case cascading dispose and prevent duplicate definitions.

## 2.0.0

- Extract core function from `zenrouter` package