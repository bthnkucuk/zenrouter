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

### Added — API

- **`StackMutatable.removeIdentical`** removes a specific live entry, matching on
  identity instead of `==`. Use it over `remove` whenever the caller knows which
  instance left and the stack may hold equal routes. It is a no-op if the route is
  already gone, so it is safe to call twice.

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