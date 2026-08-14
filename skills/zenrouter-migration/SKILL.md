---
name: zenrouter-migration
description: >
  Upgrade a project across zenrouter major versions. Use this skill when the user asks
  to upgrade, migrate, or bump zenrouter / zenrouter_core / zenrouter_devtools, when a
  build breaks after a zenrouter version change, or when they hit an error mentioning a
  removed zenrouter API.
  Triggers on: upgrade zenrouter, migrate zenrouter, bump zenrouter, zenrouter 3.0.0,
  zenrouter 2.x, breaking change, internalProps, deepEquals, PageCallback, ValueKey
  routeKey, ObjectKey routeKey, duplicate GlobalKey page, duplicated page keys,
  GuardRule canPop, canPopRule, guardRule, layoutBuilder, CoordinatorLayoutBuilder,
  RouteLayoutBuilder, parseRouteFromUri return type, createWith, bindLayout,
  defineLayoutBuilder, routerConfig, routeInformationProvider, browser history,
  back button, replace history entry.
---

# ZenRouter Migration Skill

Drive a project from an older `zenrouter` to a newer one. Work **one major version at a
time**, in order — do not jump straight to the target if the project is two majors
behind.

> Authoritative changelogs — read the relevant section before editing:
>
> | File | Covers |
> |:-----|:-------|
> | [`packages/zenrouter/MIGRATION_GUIDE.md`](../../packages/zenrouter/MIGRATION_GUIDE.md) | Full prose guide, all versions |
> | [`packages/zenrouter/CHANGELOG.md`](../../packages/zenrouter/CHANGELOG.md) | Flutter-side API changes |
> | [`packages/zenrouter_core/CHANGELOG.md`](../../packages/zenrouter_core/CHANGELOG.md) | Core model / mixin changes |

---

## Step 1 — Establish where the project is

```bash
grep -rE "^\s*zenrouter(_core|_devtools)?:" pubspec.yaml
```

Then pick the migration path:

| From | To | Section |
|:-----|:---|:--------|
| 2.x | 3.0.0 | [3.0.0 — Equality contract repair](#300--equality-contract-repair) |
| 2.0–2.2 | 2.3.0 | [2.3.0 — GuardRule contract](#230--guardrule-contract) |
| 1.x | 2.x | See `MIGRATION_GUIDE.md` — path constructors, `bindLayout`, `CoordinatorView` |

Version lockstep for 3.0.0:

```yaml
dependencies:
  zenrouter: ^3.0.0        # was ^2.3.0
  zenrouter_core: ^3.0.0   # was ^2.2.0  (only if directly depended on)

dev_dependencies:
  zenrouter_devtools: ^3.0.0  # was ^2.0.0
```

---

## 3.0.0 — Equality contract repair

**Expected blast radius: zero for most projects.** This release fixes a broken
`==` / `hashCode` contract. Bump the versions, run the analyzer, run the tests. Three
things can actually need work — check them, then stop. The third applies to web targets
only, and the analyzer will not catch it.

### What changed

| Before | After |
|:-------|:------|
| `Equatable.hashCode` mixed in `internalProps` | derived from `runtimeType` + `props` only |
| `Equatable.internalProps` | **removed** |
| `RouteTarget.deepEquals` = hash comparison | `identical(this, other)` |
| Page key = `ValueKey(route)` | `ObjectKey(route)` |
| `PageCallback` `routeKey` param: `ValueKey<T>` | `ObjectKey` |

### Check 1 — `internalProps` overrides

```bash
rg -n "internalProps" lib/ test/
```

Any hit is a compile error. `internalProps` was documented "do not override", so hits
are rare. Fix by moving identity-bearing values into `props`:

```dart
// Before
@override
List<Object?> get props => [orderId];
@override
List<Object?> get internalProps => [tenantId]; // ❌ removed

// After
@override
List<Object?> get props => [orderId, tenantId]; // ✅
```

Do **not** reintroduce per-instance mutable state (completers, controllers, path
bindings) into `props` — that recreates the bug this release fixed.

### Check 2 — explicit `ValueKey` annotations on page builders

```bash
rg -n "ValueKey<.*>\s+routeKey|ValueKey<.*>\s*\w+\s*,\s*Widget" lib/
```

Lambdas infer the type and need no change:

```dart
StackTransition(
  pageBuilder: (context, routeKey, child) => MaterialPage(key: routeKey, child: child),
  builder: (context) => const MyScreen(),
); // ✅ unaffected
```

Only a written-out annotation breaks:

```dart
// Before
Page<void> buildPage(BuildContext c, ValueKey<AppRoute> routeKey, Widget child) => ...
// After
Page<void> buildPage(BuildContext c, ObjectKey routeKey, Widget child) => ...
```

Built-in transitions (`.material`, `.cupertino`, `.sheet`, `.dialog`, `.none`) forward
the key unchanged — no action.

### Check 3 — how the `Router` is wired (web targets)

`replace` and `pushReplacement` only overwrite the browser history entry if the `Router`
is given the coordinator's `routeInformationProvider`. Passing a delegate and a parser
alone makes Flutter build its own, and the history handling never runs — silently,
because nothing about it is visible off the web.

```bash
rg -n "MaterialApp.router|CupertinoApp.router|WidgetsApp.router" -A 5 lib/
```

If the call passes `routerDelegate` and `routeInformationParser` without
`routeInformationProvider`, collapse it:

```dart
// Before
MaterialApp.router(
  routerDelegate: coordinator.routerDelegate,
  routeInformationParser: coordinator.routeInformationParser,
);
// After
MaterialApp.router(routerConfig: coordinator);
```

Keep the long form only if something else needs the pieces separately; then add
`routeInformationProvider: coordinator.routeInformationProvider`.

Debug web builds report a `FlutterError` for this, so a running app will say so too.

### Cleanup opportunity — delete Set/Map workarounds

Routes were previously unusable as `Set` elements or `Map` keys: `set.contains(route)`
returned `false` for an equal route. If the project worked around that (comparing
`toUri()`, keying by id string, linear `firstWhere` scans over a list), those
workarounds can now be replaced with plain collection lookups.

```bash
rg -n "firstWhere.*==|indexWhere.*toUri\(\)|\.toUri\(\)\.toString\(\)" lib/
```

Treat these as *optional* cleanups; only touch them if the user asked for cleanup.

### Cleanup opportunity — delete navigation-ordering workarounds

Path mutations are now serialized: they apply one at a time, in call order. Projects
that hit the old races often papered over them with delays or manual sequencing between
navigation calls.

```bash
rg -n "Future.delayed.*(push|pop|navigate)|await Future.delayed" lib/
```

If a delay exists only to make two navigation calls land in the right order, it can go.
Leave delays that serve animation or UX purposes.

A pending `await coordinator.push(...)` now also resolves — with `null` — when its path
is disposed, where it used to hang forever. Code after such an `await` runs in one more
case than before, so check that it tolerates a `null` result; that is the same value an
unvalued pop already produced.

```bash
rg -n "await\s+\w*\.?push\s*[<(]" lib/
```

In a declarative stack, returning a value from a screen that outlived a `routes` update
used to throw `Bad state: Future already completed`. Projects that routed around it —
returning results through app state instead of `Navigator.pop(context, value)` — can go
back to the plain API.

Similarly, `Navigator.of(context).pop()` from a widget now syncs the path correctly.
Projects that funnelled every pop through `coordinator.pop()` only to avoid the old
mismatch can stop; `Navigator` pops, swipe back and predictive back all remove the entry
whose page actually closed.

Also drop guards that re-checked what got popped: `pop` now removes the route its guard
approved, never one that raced to the top.

### If `push` now asserts "already on this path"

Cause: the **same route instance** is pushed onto one stack twice.

```dart
final route = EditRoute();
path.push(route);
path.push(route); // ❌ one instance cannot own two stack entries
```

A `RouteTarget` carries one path binding and one result completer, so it maps to exactly
one entry — pushing it twice makes both `push` futures share a completer and unbinds the
surviving entry. Before 3.0.0 this surfaced as an opaque Flutter crash
(`'_dependents.isEmpty': is not true`); it is now caught at the push site. Fix by
constructing a fresh instance per push:

```dart
path.push(EditRoute());
path.push(EditRoute()); // ✅
```

**Do not "fix" this by deduplicating the stack.** Two *equal but distinct* instances
(`[/edit, /settings, /edit]`) are legal and are exactly what this release repaired — the
assert fires only on literal instance reuse (`identical`), never on value equality.

---

## 2.3.0 — GuardRule contract

`GuardRule` methods were renamed for coordinator-optional use:

| Removed | Replacement |
|:--------|:------------|
| `canPop(route)` | `canPopRule(route)` / `canPopRuleWith(coordinator, route)` |
| `canPopListenable(route)` | `canPopListenableRule(route)` / `canPopListenableRuleWith(coordinator, route)` |
| `guard(coordinator, route)` | `guardRule(route)` / `guardRuleWith(coordinator, route)` |

```bash
rg -n "extends GuardRule|implements GuardRule" lib/
```

Use the route-only form when no coordinator is needed; override the `*With` form when
the rule needs a coordinator (dialogs, app state). Each `*With` defaults to its
non-`With` counterpart.

---

## Step 2 — Verify

Run in order, and do not report success until all three are clean:

```bash
flutter pub get
```

```bash
flutter analyze
```

```bash
flutter test
```

If tests fail, read the failure before editing — after a 3.0.0 upgrade a failure is more
likely to be a **latent bug the contract repair exposed** than a regression the upgrade
introduced. Verify by checking whether the same test fails on the pre-upgrade revision.

---

## Reporting back

State plainly:

- Which versions were bumped, in which pubspecs.
- Which of the checks above produced actual edits (often: none).
- Analyzer and test results, with counts.
- Anything deliberately left alone (e.g. optional Set/Map cleanups).
