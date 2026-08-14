import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';
import 'package:zenrouter_devtools/zenrouter_devtools.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      // Without this there is no bucket for the tabs to restore into, and the
      // note fields below come back empty.
      restorationScopeId: 'tabs-demo',
      routerConfig: appCoordinator,
    );
  }
}

// ============================================================================
// Coordinator
// ============================================================================

final appCoordinator = AppCoordinator();

class AppCoordinator extends Coordinator<AppRoute> with CoordinatorDebug {
  /// Flip either flag and hot restart to compare — see [_TabBody].
  ///
  /// They are separate on purpose: [lazy] is about a tab nobody has opened,
  /// [pauseHiddenTabs] about one that is open but off screen.
  late final tabPath = IndexedStackPath.createWith(
    coordinator: this,
    label: 'tabs',
    lazy: true,
    pauseHiddenTabs: true,
    [HomeTab(), SearchTab(), ProfileTab()],
  )..bindLayout(TabLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, tabPath];

  @override
  List<AppRoute> get debugRoutes => [HomeTab(), SearchTab(), ProfileTab()];

  @override
  AppRoute parseRouteFromUri(Uri uri) {
    return switch (uri.pathSegments) {
      [] || ['home'] => HomeTab(),
      ['search'] => SearchTab(),
      ['profile'] => ProfileTab(),
      ['settings'] => SettingsRoute(),
      _ => HomeTab(),
    };
  }
}

// ============================================================================
// Route Base
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

// ============================================================================
// Tab Layout
// ============================================================================

class TabLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  IndexedStackPath<AppRoute> resolvePath(AppCoordinator coordinator) =>
      coordinator.tabPath;

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    final path = coordinator.tabPath;
    return Scaffold(
      body: buildPath(coordinator),
      bottomNavigationBar: ListenableBuilder(
        listenable: path,
        builder: (context, _) => BottomNavigationBar(
          currentIndex: path.activeIndex,
          onTap: (index) => path.goToIndexed(index),
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
            BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
            BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Tab Routes
// ============================================================================

class SettingsRoute extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/settings');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const Center(
        child: Text('Settings', style: TextStyle(fontSize: 24)),
      ),
    );
  }
}

class HomeTab extends AppRoute {
  @override
  Type get layout => TabLayout;

  @override
  Uri toUri() => Uri.parse('/home');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return const _TabBody(title: 'Home');
  }
}

class SearchTab extends AppRoute {
  @override
  Type get layout => TabLayout;

  @override
  Uri toUri() => Uri.parse('/search');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return const _TabBody(title: 'Search');
  }
}

class ProfileTab extends AppRoute {
  @override
  Type get layout => TabLayout;

  @override
  Uri toUri() => Uri.parse('/profile');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return const _TabBody(title: 'Profile');
  }
}

// ============================================================================
// What the tabs are for
// ============================================================================

/// Shows the three things that separate a lazy indexed stack from an eager one.
///
/// **When it was built.** Eagerly, every tab reports the same startup moment —
/// each one ran its `initState` before you saw anything. Lazily, only the tab
/// you land on does, and the others fill in as you visit them.
///
/// **That it keeps running.** The dot spins while its tab is ticking, and the
/// counter under it says how many frames it has cost. Flutter's `IndexedStack`
/// keeps every child ticking, so by default a hidden tab goes on animating — and
/// rebuilding — for as long as the app is open. With `pauseHiddenTabs` it stops
/// on leaving and picks up on return.
///
/// **That it remembers.** Every tab's field uses the *same* `restorationId`, so
/// it is also the check that the tabs get a restoration scope each: each tab
/// keeps its own text rather than sharing one bucket with the others.
///
/// That last one needs a platform that restores. The engine decides — the
/// `restoration` channel reports whether the embedder supports it — and today
/// that means **Android and iOS only**; on desktop and web it is off, and every
/// field comes back empty. A **hot restart is not a restart** either: the
/// system hands the data back when *it* relaunches the app, so the way to see
/// this by hand is Android with "Don't keep activities" turned on, then
/// backgrounding the app and returning. The line under the field says which of
/// the two situations you are in.
class _TabBody extends StatefulWidget {
  const _TabBody({required this.title});

  final String title;

  @override
  State<_TabBody> createState() => _TabBodyState();
}

class _TabBodyState extends State<_TabBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  late final DateTime builtAt = DateTime.now();

  int frames = 0;

  @override
  void dispose() {
    spin.dispose();
    super.dispose();
  }

  String get _stamp {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(builtAt.hour)}:${two(builtAt.minute)}:${two(builtAt.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24),
          ),
          const SizedBox(height: 8),
          Text(
            'built at $_stamp',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 24),
          Center(
            child: RotationTransition(
              turns: spin,
              child: AnimatedBuilder(
                animation: spin,
                builder: (context, child) {
                  frames++;
                  return child!;
                },
                child: const Icon(Icons.sync, size: 32),
              ),
            ),
          ),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: spin,
            builder: (context, _) => Text(
              'frames rendered: $frames',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          const SizedBox(height: 24),
          const TextField(
            // The same id in all three tabs, on purpose.
            restorationId: 'note',
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'A note the system restores',
            ),
          ),
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              // No bucket above means the engine turned restoration off, so
              // nothing here can be restored however it is written.
              final restores = RestorationScope.maybeOf(context) != null;
              return Text(
                restores
                    ? 'state restoration: on — the system will hand this back'
                    : 'state restoration: off on this platform '
                          '(Android and iOS only, and not on hot restart)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: restores ? Colors.green.shade700 : Colors.black54,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
