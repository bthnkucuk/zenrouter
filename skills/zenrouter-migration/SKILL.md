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
  back button, replace history entry, CoordinatorNavigatorObserver, observers,
  observersBuilder, NavigatorObserver, observer.navigator == null,
  pop animation missing, exit transition, TransitionDelegate, ZenTransitionDelegate,
  dialog route, layoutKey, parentLayoutKey, nested navigator.
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
`==` / `hashCode` contract. Bump the versions, run the analyzer, run the tests. Five
things can actually need work — check them, then stop. The analyzer catches the first
two and flags the fifth as a deprecation; the third applies to web targets, and the
fourth shows up as a debug assert at runtime.

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

### Check 4 — `props` completeness (a new assert may fire)

`navigate` and `pushOrMoveToTop` match an existing entry by comparing `props`. Routes
that interpolate a field into `toUri()` but leave it out of `props` now assert instead of
silently landing on the wrong entry.

```bash
rg -n "Uri toUri\(\)" -A 2 lib/ | rg -n "\$"
```

For every route whose `toUri()` interpolates something, check that the same field is in
`props`:

```dart
Uri toUri() => Uri.parse('/order/$id');
@override
List<Object?> get props => [id];   // must include id
```

An assert firing here is a real bug the release surfaced, not a regression — the app was
navigating to the wrong screen before. Fix the `props`, do not silence the assert.

The mirror also asserts: `props` containing per-instance state (a completer, a callback,
a timestamp) makes identical destinations compare unequal, so `pushOrMoveToTop` pushes
duplicates.

### Check 5 — `CoordinatorNavigatorObserver.observers`

Deprecated. It gave one list to every navigator a coordinator runs, which Flutter
forbids — `NavigatorState.initState` asserts `observer.navigator == null`.

```bash
rg -n "CoordinatorNavigatorObserver|get observers" lib/
```

```dart
// Before
@override
List<NavigatorObserver> get observers => [_analytics];

// After
@override
NavigatorObserverListGetter get observersBuilder =>
    () => [AnalyticsObserver(analyticsSink)];
```

The builder must return **new** observers each call — it is invoked once per navigator.
Anything that has to outlive a navigator (counters, subscriptions) belongs in an object
the app owns and passes in, not in the observer itself. Do not "fix" this by returning a
cached instance; that is the shared-instance case the assert is about.

### Cleanup opportunity — data that was pushed into `props` to force a refresh

Navigating to a route already on the stack now refreshes its page. Projects that hit the
old staleness sometimes worked around it by adding the changing data to `props`, which
makes the routes unequal so a second page gets pushed instead.

```bash
rg -n "get props" -B 6 lib/ | rg -n "String |int |bool "
```

If a field is in `props` but not in `toUri()`, it is data rather than identity and can
move out — pushing a page per data change grows the stack and leaves several entries
claiming the same URL. Optional; only touch it if the user asked for cleanup.

### Cleanup opportunity — nested navigators added only to keep an exit animation

Flutter's `DefaultTransitionDelegate` drops a page's exit animation whenever anything sits
above it, so a "discard changes?" dialog made the screen underneath snap away instead of
sliding. `NavigationStack` now installs `ZenTransitionDelegate`, which keeps the
transition when the thing above never covered the page — an already-dismissed
`showDialog` route, or a non-opaque page (`StackTransition.dialog` / `.sheet`) leaving in
the same frame.

The usual workaround was to give the screen its own navigator so the two pops happened in
different navigators:

```bash
rg -n "layoutKey|parentLayoutKey" lib/
```

A sentinel key plus a `RouteLayout` plus an internal seed route, all to separate two pops,
can now be deleted — the screen goes back to being an ordinary route and the dialog back
onto the same stack. Two follow-ups when you do:

- A parameterised route that was forced into `RouteLayout` had to hand-write `==` /
  `hashCode`, because `RouteLayout` compares by `layoutKey` / `parentLayoutKey` and would
  otherwise collapse every `/flow/<slug>` into one destination. Drop that override too.
- A pop guard runs inside the path's mutation queue, so `await coordinator.push(...)` from
  inside `popGuardWith` waits for the pop it is deciding. Push the dialog route from the
  screen, or use `showDialog` inside the guard.

Only touch this if the user asked for cleanup, or if they mention a missing pop animation.

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
