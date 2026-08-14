# Migration Guide

This guide outlines the changes and steps required to migrate to the latest version of `zenrouter`.

**Latest:** [3.0.0](#300-equality-contract-repair) — `hashCode` contract repair, `internalProps` removal, identity-based page keys.

---

## 3.0.0: Equality contract repair

**TL;DR — most projects need no code changes**, with one exception: web apps should
check how they wire the `Router`. Run your test suite, then work through
[Do I need to change anything?](#do-i-need-to-change-anything) below.

### What was wrong

`Equatable.hashCode` mixed in `internalProps`, and `RouteTarget.internalProps` returned
`[runtimeType, _path, _onResult]`. `_onResult` is a `Completer` created fresh per
instance, so two routes that compared **equal** always hashed **differently**:

```dart
final a = ProductRoute('42');
final b = ProductRoute('42');

a == b;                   // true
a.hashCode == b.hashCode; // false  ← violates Dart's core contract
```

Dart requires `a == b ⇒ a.hashCode == b.hashCode`. Breaking it silently corrupts every
hash-based lookup:

```dart
{a}.contains(b);            // false — but a == b
<Route, int>{a: 1}[b];      // null  — but a == b
```

It also hid a second defect. `NavigationStack` keyed pages with `ValueKey(route)`, so an
ordinary stack like `[/edit, /settings, /edit]` produced two `==`-equal page keys.
Flutter's `Navigator` reserves page keys in a `Set<Key>`; because the hash codes
disagreed, the duplicate-key assert never fired and the collision went unnoticed.

### What changed

| Before | After |
|---|---|
| `hashCode` = `mapPropsToHashCode(internalProps) ^ mapPropsToHashCode(props)` | `hashCode` = `runtimeType.hashCode ^ mapPropsToHashCode(props)` |
| `Equatable.internalProps` (public, "do not override") | **removed** |
| `RouteTarget.deepEquals` = `hashCode == other.hashCode` | `identical(this, other)` |
| Page key = `ValueKey(route)` (by value) | `ObjectKey(route)` (by instance) |
| `PageCallback` `routeKey` param: `ValueKey<T>` | `ObjectKey` |

### Do I need to change anything?

**1. Did you override `internalProps`?**

It was documented as "**Do not override**", so almost certainly not. If you did, delete
the override — and move anything that genuinely affects route identity into `props`:

```dart
// Before
class OrderRoute extends RouteTarget with RouteUnique {
  @override
  List<Object?> get props => [orderId];

  @override
  List<Object?> get internalProps => [tenantId]; // ❌ no longer exists
}

// After
class OrderRoute extends RouteTarget with RouteUnique {
  @override
  List<Object?> get props => [orderId, tenantId]; // ✅ identity lives in props
}
```

**2. Are you on the web? Check how you wire the `Router`.**

`replace` and `pushReplacement` now overwrite the browser history entry instead of
adding one, so signing in through a `replace` no longer leaves `/login` one back-press
away. That only takes effect if the `Router` is given the coordinator's
`routeInformationProvider`:

```dart
// Before — Flutter builds its own provider, and history handling never runs
MaterialApp.router(
  routerDelegate: coordinator.routerDelegate,
  routeInformationParser: coordinator.routeInformationParser,
);

// After
MaterialApp.router(routerConfig: coordinator);
```

If you need the pieces separately, pass the provider too:

```dart
MaterialApp.router(
  routerDelegate: coordinator.routerDelegate,
  routeInformationParser: coordinator.routeInformationParser,
  routeInformationProvider: coordinator.routeInformationProvider,
);
```

Debug web builds report a `FlutterError` when the provider is missing, so you will not
have to discover this by pressing back.

**3. Run the app in debug — a new assert may fire on `navigate` / `pushOrMoveToTop`.**

Both match an existing entry by comparing `props`. If `props` omits a field the route is
identified by, two destinations compare equal and the match silently lands on the wrong
one — a deep link to `/order/8123` leaving you on `/order/5500`, with the URL corrected
back. That is now an assert instead of a wrong screen:

```
navigate matched a route with a different URI.
  asked for  /order/8123
  matched    /order/5500
```

The fix is to list the fields that identify the route — usually the ones interpolated
into `toUri()`:

```dart
class OrderRoute extends RouteTarget with RouteUnique {
  OrderRoute(this.id);
  final String id;

  @override
  Uri toUri() => Uri.parse('/order/$id');

  @override
  List<Object?> get props => [id];   // ← add this
}
```

The mirror also asserts: no entry compared equal while one on the stack has the very same
URI. That means `props` holds per-instance state — a completer, a callback, a timestamp —
so a route that should move to the top is pushed again. Keep `props` to the values that
identify the destination.

Query-only differences are not flagged: `RouteQueryParameters` is meant to keep a route's
identity while its queries change.

**4. Did you annotate a `pageBuilder` parameter explicitly?**

Lambdas are unaffected — the type is inferred:

```dart
StackTransition(
  pageBuilder: (context, routeKey, child) => MaterialPage(key: routeKey, child: child),
  builder: (context) => const MyScreen(),
);
```

Only a written-out `ValueKey<T>` annotation breaks:

```dart
// Before
Page<void> buildPage(BuildContext context, ValueKey<AppRoute> routeKey, Widget child) => ...
// After
Page<void> buildPage(BuildContext context, ObjectKey routeKey, Widget child) => ...
```

All built-in transitions (`.material`, `.cupertino`, `.sheet`, `.dialog`, `.none`)
forward the key unchanged and need no action.

### Behaviour you may notice

- **Routes now work correctly in `Set` / `Map`.** If you wrote a workaround for routes
  "not being found" in a collection, you can delete it.
- **Equal-but-distinct layout instances.** `RouteLayoutParent` / `RouteLayout` override
  `==` by layout key. `deepEquals` is now identity, so passing a *new* equal layout
  instance to `navigate` / `pushOrMoveToTop` correctly discards the redundant instance
  and clears its stack-path binding, instead of leaving it bound.
- **Duplicate routes in one stack are now legal.** `[/edit, /settings, /edit]` renders
  two independent pages, as it always should have.
- **`onUpdate` now actually reaches the screen.** Navigating to a route already on the
  stack hands the existing route the new data instead of pushing a duplicate — but the
  page was reused, so the screen kept the old values. It refreshes now, keeping its
  widget state. If you worked around this by putting the data in `props` so a second
  page would be pushed, you can move it back out: `props` is the destination's identity,
  and pushing a page per data change grows the stack and gives several entries the same
  URL. Overrides of `onUpdate` must call `super.onUpdate(newRoute)`; it is
  `@mustCallSuper`, so the analyzer already says so.
- **Replacements stop piling up browser history.** On the web, `replace` and
  `pushReplacement` used to add an entry each, so the back button walked into screens
  the app had discarded. `pushReplacement` added two — being a pop followed by a push,
  it reported a transient state the user never saw. Both now overwrite the current
  entry. Requires the wiring described above; no effect off the web.
- **A pending `await push(...)` no longer hangs when its path is disposed.** Nothing
  used to complete the result of routes still on a stack being torn down, so the code
  after the `await` never ran and the awaiting frame kept its state alive. Those awaiters
  now resolve with `null`. Check any `await coordinator.push(...)` that assumed it would
  only resume on a real pop — it can now also resume because the path went away, with
  `null`, which is the same value an unvalued pop gives you.
- **Declarative updates are a single commit.** If you use
  `NavigationStack.declarative`, changing the `routes` list used to rebuild the path one
  route at a time, completing the result of every route that survived the change. A
  screen that outlived an update and later returned a value crashed with
  `Bad state: Future already completed`. Nothing to change — but if you avoided
  `Navigator.pop(context, value)` in a declarative stack because of it, you no longer
  need to.
- **Popping outside the coordinator now syncs correctly.** If a widget calls
  `Navigator.of(context).pop()` — a shared close button, a form that does not know about
  zenrouter — or the user swipes back, the path used to remove the first *value-equal*
  route rather than the one whose page actually closed. On `[/edit, /settings, /edit]`
  that took out the wrong `/edit` and left the path disagreeing with the screen. Page
  keys now name the exact instance, so the right entry leaves. Nothing to change; if you
  routed such widgets through `coordinator.pop()` purely to dodge this, that is no longer
  necessary.
- **Navigation on a path is serialized.** Mutations now apply one at a time, in call
  order. If you fire several without awaiting them, they still all apply — just in
  sequence rather than racing. Two things follow:
  - A push arriving while an async pop guard is open no longer steals that pop. This
    was a real hole: a deep link landing during a "discard unsaved changes?" dialog
    would be the route removed when the user confirmed, and its own guard was never
    consulted even if it refused every pop.
  - `push(a)` then `push(b)` now always ends with `b` on top, even when `a`'s redirect
    (an auth check, say) is slower than `b`'s.

  Timing is unchanged where there is nothing to protect: an unguarded `pop` has no
  await gap and still applies synchronously, and the first mutation starts immediately
  when nothing else is in flight. If you have a workaround that inserted delays between
  navigation calls to keep them ordered, you can drop it.

### One instance, one entry

Pushing the **same instance** twice was never supported:

```dart
final route = EditRoute();
path.push(route);
path.push(route); // ❌ one instance cannot own two stack entries
```

A `RouteTarget` carries a single path binding and a single result completer, so it maps
to exactly one stack entry — pushing it twice makes both `push` futures share a
completer and unbinds the surviving entry. This was already true before 3.0.0, but it
surfaced as an opaque `_dependents.isEmpty` crash from Flutter. `push` now asserts on it
directly, naming the route and the fix. Push a new instance per entry:

```dart
path.push(EditRoute());
path.push(EditRoute()); // ✅
```

Note the distinction: two **equal but distinct** instances (`[/edit, /settings, /edit]`)
are fully supported — that is exactly what this release fixes. Only literal instance
reuse is rejected.

---

## 2.1.0: CoordinatorView & layout builder API

### Adopting `CoordinatorView` (optional)

2.1.0 adds [`CoordinatorView`](doc/guides/coordinator-view.md) for embedding a standalone coordinator **without** `MaterialApp.router`. No migration is required unless you want this pattern.

**App root (unchanged — recommended for web / single-surface apps):**

```dart
MaterialApp.router(routerConfig: appCoordinator)
```

**Embedded surface (new):**

```dart
MaterialApp(
  home: CoordinatorView<AppRoute>(
    coordinator: miniAppCoordinator,
    initialUri: Uri.parse('/dashboard'),
  ),
)
```

| Concern | `routerConfig` | `CoordinatorView` |
|---------|----------------|-------------------|
| Browser URL / back button | Automatic | Host must handle |
| `initialUri` | Platform + parser | Once, when `root.stack` is empty |
| Ongoing deep links | `setNewRoutePath` | Call `coordinator.navigate(...)` explicitly |

See [CoordinatorView Guide](doc/guides/coordinator-view.md) for pitfalls, parallel panels, and mini-app hosts.

---

### `layoutBuilder` moved to `CoordinatorLayout`

#### Changes

- **Before**: `layoutBuilder` was declared on the `Coordinator` class.
- **After**: `layoutBuilder` lives on the [`CoordinatorLayout`](lib/src/coordinator/layout.dart) mixin (via [`CoordinatorLayoutBuilder`](lib/src/coordinator/layout.dart)).

#### Migration

If you override `layoutBuilder`, keep overriding it on your coordinator class — `Coordinator` still mixes in `CoordinatorLayout`. No import or call-site changes are needed for typical apps.

**Before and after (same for `extends Coordinator`):**

```dart
class AppCoordinator extends Coordinator<AppRoute> {
  @override
  Widget layoutBuilder(BuildContext context) {
    return RouteLayout.buildRoot(this);
  }
}
```

Only update code that referenced `layoutBuilder` as a member **defined on `Coordinator` itself** in documentation, implements clauses, or custom abstractions that extended `CoordinatorCore` without `CoordinatorLayout`. Those types must now mix in or implement `CoordinatorLayoutBuilder`.

---

### `RouteLayoutBuilder` first parameter: `CoordinatorCore`

#### Changes

- **Before**: `Widget Function(Coordinator coordinator, StackPath<T> path, RouteLayout<T>? layout)`
- **After**: `Widget Function(CoordinatorCore coordinator, StackPath<T> path, RouteLayout<T>? layout)`

#### Migration

Update custom layout builders registered with `defineLayoutBuilder` (or copies of `kDefaultLayoutBuilderTable`). Cast when you need Flutter-specific APIs:

**Before:**

```dart
coordinator.defineLayoutBuilder(
  NavigationPath.key,
  (Coordinator coordinator, path, layout) {
    return NavigationStack(
      path: path as NavigationPath<AppRoute>,
      coordinator: coordinator,
      // ...
    );
  },
);
```

**After:**

```dart
coordinator.defineLayoutBuilder(
  NavigationPath.key,
  (CoordinatorCore coordinatorCore, path, layout) {
    final coordinator = coordinatorCore as Coordinator;
    return NavigationStack(
      path: path as NavigationPath<AppRoute>,
      coordinator: coordinator,
      // ...
    );
  },
);
```

If your builder only uses `coordinator.root`, `getLayoutBuilder`, or other members on `CoordinatorCore` / `CoordinatorLayout`, no cast is required.

**Default builders (`NavigationPath` / `IndexedStackPath`):** [`kDefaultLayoutBuilderTable`](lib/src/coordinator/layout.dart) still require a Flutter **`Coordinator`**, not an arbitrary `CoordinatorCore`. In debug builds, passing the wrong type triggers an `assert` with a link to [route-layout.md — default layout builders](doc/guides/route-layout.md#default-layout-builders-require-coordinator). Register `defineLayoutBuilder` if you use a custom core type.

#### Rationale

Layout builders are shared infrastructure; the narrower parameter type matches `RouteLayout.buildRoot` and allows future embed hosts that implement `CoordinatorLayoutBuilder` without full `RouterConfig`.

---

### `RouteLayout.buildRoot` parameter: `CoordinatorLayout`

#### Changes

- **Before**: `RouteLayout.buildRoot(Coordinator coordinator)`
- **After**: `RouteLayout.buildRoot(CoordinatorLayout coordinator)`

#### Migration

Pass `this` from any class that mixes in `CoordinatorLayout` (including `Coordinator`). Update helpers that accepted `Coordinator` only for `buildRoot`:

**Before:**

```dart
Widget buildAppShell(Coordinator coordinator) => RouteLayout.buildRoot(coordinator);
```

**After:**

```dart
Widget buildAppShell(CoordinatorLayout coordinator) => RouteLayout.buildRoot(coordinator);
```

`Coordinator` satisfies `CoordinatorLayout`; existing `layoutBuilder` overrides that delegate to `RouteLayout.buildRoot(this)` continue to work unchanged.

---

### `CoordinatorLayoutBuilder` mixin

#### Changes

- **New**: `CoordinatorLayoutBuilder<T extends RouteUri>` declares `Widget layoutBuilder(BuildContext context)`.
- **New**: [`CoordinatorView`](lib/src/coordinator/view.dart) takes `CoordinatorLayoutBuilder<T> coordinator` instead of requiring full `Coordinator` / `RouterConfig`.

#### Migration

No action required unless you build custom embed widgets. Prefer typing embed APIs against `CoordinatorLayoutBuilder<T>` rather than `Coordinator<T>` when URL sync and `Router` are not needed.

---

## Path Constructors

The constructors for `NavigationPath` and `IndexedStackPath` have been updated to provide better clarity and type safety, especially when binding to a `Coordinator`.

### Changes

- **Deprecated**: The default unnamed constructors `NavigationPath(...)` and `IndexedStackPath(...)`.
- **New**: `create` factory constructor for creating paths with optional arguments.
- **New**: `createWith` factory constructor for creating paths that are explicitly bound to a `Coordinator`.

### Migration

Replace direct constructor calls with `create` or `createWith`:

**Before:**
```dart
final path = NavigationPath(
  'root',
  [],
  coordinator,
);
```

**After (Standard):**
```dart
final path = NavigationPath.create(
  label: 'root',
  stack: [],
  coordinator: coordinator,
);
```

**After (With explicit Coordinator):**
```dart
late final path = NavigationPath.createWith(
  coordinator: this,
  label: 'root',
  stack: [],
);
```

Same applies to `IndexedStackPath`.

### Rationale

Deeply integrating paths with their coordinator using `createWith` provides several benefits:

1.  **Coordinator Awareness**: The path explicitly knows which coordinator it belongs to, enabling features like `popGuardWith` to verify that operations are happening in the correct context.
2.  **Safety**: Prevents a path from being used detached from its coordinator, which could lead to silent failures or incorrect state management.
3.  **Strict Binding**: The `late final ... = ... .createWith(coordinator: this, ...)` pattern ensures that the path and coordinator are 1:1 linked from the moment of creation, avoiding race conditions or initialization order issues.

### Trade-offs

*   **Coupling**: This approach tightly couples instances of `StackPath` to a specific `Coordinator`. While this is by design, it means paths are less "standalone".
*   **Testing**: Unit testing individual paths in isolation now requires providing a mock or dummy `Coordinator` if you use `createWith`, whereas previously they could be tested as simple data containers.
*   **Initialization**: Requires using `late final` variables in the `Coordinator` to handle the circular reference (Coordinator needs Path, Path needs Coordinator). Exceptions during initialization might be harder to debug if not careful.

**Why it is worth it:**
When using `createWith`, you are explicitly creating a path intended to work *with* a Coordinator. Therefore, this coupling is intentional and necessary. It guarantees that the path always has access to the correct context for advanced features like guards and redirects, making the system more robust and preventing common configuration errors.

## Path Layout Builder: `defineLayoutBuilder()`

The `RouteLayout.definePath()` static method has been deprecated and replaced by the instance method `coordinator.defineLayoutBuilder()`.

### Changes

- **Deprecated**: The static method `RouteLayout.definePath(coordinator, key, builder)`.
- **New**: The instance method `coordinator.defineLayoutBuilder(key, builder)`.

### Migration

Replace calls to the static `RouteLayout.definePath` with the `defineLayoutBuilder` method on your coordinator instance.

**Before:**
```dart
// Static definition
RouteLayout.definePath(
  NavigationPath.key,
  (coordinator, path, layout) => CustomNavigationStack(...),
);
```

**After:**
```dart
// Instance definition
coordinator.defineLayoutBuilder(
  NavigationPath.key,
  (coordinator, path, layout) => CustomNavigationStack(...),
);
```

### Rationale

Moving `defineLayoutBuilder` to the `Coordinator` instance solves a critical architectural issue by **avoiding global state**:

1. **Scoped State**: Layout builders are now scoped to the specific `Coordinator` instance rather than sitting in a static global context. This ensures that multiple coordinators (e.g., in testing or advanced architectures) do not interfere with each other's custom layout builders.
2. **Lifecycle Management**: By associating the builder table with the coordinator, it automatically cleans up when the coordinator is disposed, preventing memory leaks.

## Layout Registration: `bindLayout()`

The layout registration API has been simplified from `defineLayout()` to `bindLayout()`.

### Changes

- **Deprecated**: `defineLayout()` method with `RouteLayout.defineLayout()` calls.
- **New**: `bindLayout()` method on `StackPath` for inline layout registration.

### Migration

**Before (using defineLayout):**
```dart
class AppCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> homeStack = NavigationPath.createWith(
    label: 'home',
    coordinator: this,
  )..bindLayout(HomeLayout.new);
}
```

**After (using bindLayout):**
```dart
class AppCoordinator extends Coordinator<AppRoute> {
  late final NavigationPath<AppRoute> homeStack = NavigationPath.createWith(
    label: 'home',
    coordinator: this,
  )..bindLayout(HomeLayout.new);  // Register inline!

  // No need to override defineLayout() when using bindLayout
}
```

Both approaches work, but `bindLayout()` is recommended for new code.

### Benefits

- **More concise**: Single line instead of separate method override
- **Collocated**: Path creation and layout registration in one place
- **Less boilerplate**: No need to override `defineLayout()`

## RouteGuard API

The `RouteGuard` mixin has been enhanced to support coordinator validation during pop operations.

### Changes

- **New**: `popGuardWith(Coordinator coordinator)` method.
  - This method is called by the framework when a pop is attempted.
  - It asserts that the route's path is associated with the correct coordinator.
  - It internally calls `popGuard()`.

- **Existing**: `popGuard()` remains the place to implement your custom guard logic.

### Migration

If you are manually calling `popGuard` in your custom logic or tests, consider using `popGuardWith` if you have access to the coordinator to benefit from the additional checks.

No changes are needed for existing `popGuard` implementations unless you are overriding the default behavior significantly.

## RouteRedirect API

The `RouteRedirect` mixin has been updated similarly to `RouteGuard`.

### Changes

- **New**: `redirectWith(Coordinator coordinator)` method.
  - Called by the framework during route resolution.
  - Helps ensuring the path belongs to the correct coordinator context.
  - Internally calls `redirect()`.

- **Existing**: `redirect()` remains the place to implement your redirect logic.

## parseRouteFromUri Return Type

The return type of `parseRouteFromUri` has been changed to support nullable returns.

### Changes

- **Before**: `FutureOr<T> parseRouteFromUri(Uri uri)`
- **After**: `FutureOr<T?> parseRouteFromUri(Uri uri)`

### Migration

For most coordinators, no changes are needed. The nullable return is primarily for nested coordinators (route modules) that want to indicate "this URI doesn't belong to me".

```dart
// Before
@override
FutureOr<AppRoute> parseRouteFromUri(Uri uri) { ... }

// After - return null to let parent handle unrecognized URIs
@override
FutureOr<AppRoute?> parseRouteFromUri(Uri uri) { ... }
```

## Internal Properties (`internalProps`)

> **⚠️ Superseded — `internalProps` was removed in 3.0.0.** This section describes a
> 2.0-era change and is kept for historical reference only. Folding per-instance state
> into `hashCode` turned out to *break* Dart's equality contract rather than improve it,
> which is exactly what made sets of routes unreliable. See
> [3.0.0: Equality contract repair](#300-equality-contract-repair).

A new property `internalProps` has been introduced to the `Equatable` base class (and consequently `RouteTarget`) to handling deep comparison and hashing of internal state.

### Changes

- **`internalProps`**: A list of properties used for calculating `hashCode` and ensuring object identity, separate from the public `props`.
- `RouteTarget` now includes `runtimeType`, `_path`, and the internal result completer in `internalProps`.

### Impact

This ensures that `RouteTarget` instances are correctly distinguished even if they have identical configuration `props`, especially when they belong to different paths or have different lifecycle states. This improves the reliability of deep comparisons and sets containing routes.
