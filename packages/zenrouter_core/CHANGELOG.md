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