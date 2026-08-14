import 'dart:async';
import 'dart:developer' show log;

import 'package:flutter/material.dart';
import 'package:zenrouter/zenrouter.dart';
import 'package:zenrouter_devtools/zenrouter_devtools.dart';

// ============================================================================
// Main App Entry Point
// ============================================================================

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static final coordinator = AppCoordinator();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ZenRouter Nested Routes Example',
      restorationScopeId: 'main_coordinator',
      routerConfig: coordinator,
    );
  }
}

// ============================================================================
// Route Definitions
// ============================================================================

/// Base route class for all app routes
abstract class AppRoute extends RouteTarget with RouteUnique {}

/// Home layout - uses NavigatorStack for nested navigation within home
class HomeLayout extends AppRoute with RouteLayout<AppRoute>, RouteTransition {
  @override
  NavigationPath<AppRoute> resolvePath(AppCoordinator coordinator) =>
      coordinator.homeStack;

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(kToolbarHeight),
        child: ListenableBuilder(
          listenable: coordinator.tabIndexed,
          builder: (context, child) => AppBar(
            title: Text(switch (coordinator.tabIndexed.activeIndex) {
              0 => 'Feed',
              1 => 'Profile',
              2 => 'Settings',
              _ => 'Home',
            }, style: TextStyle(color: Colors.white)),
            backgroundColor: Colors.blue,
          ),
        ),
      ),
      body: buildPath(coordinator),
    );
  }

  @override
  StackTransition<T> transition<T extends RouteUnique>(
    AppCoordinator coordinator,
  ) {
    return StackTransition.cupertino(
      Builder(builder: (context) => build(coordinator, context)),
    );
  }
}

/// Tab bar shell - uses Custom (IndexedStack) for tab navigation
class TabBarLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  Type get layout => HomeLayout;

  @override
  IndexedStackPath<AppRoute> resolvePath(AppCoordinator coordinator) =>
      coordinator.tabIndexed;

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    final path = coordinator.tabIndexed;
    return Scaffold(
      body: Column(
        children: [
          // Tab content (IndexedStack is built by RouteLayout)
          Expanded(child: buildPath(coordinator)),
          // Tab bar
          ListenableBuilder(
            listenable: path,
            builder: (context, child) => BottomNavigationBar(
              items: [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Feed'),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person),
                  label: 'Profile',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
              currentIndex: path.activeIndex,
              onTap: (index) => coordinator.tabIndexed.goToIndexed(index),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings shell - uses NavigatorStack for nested settings navigation
class SettingsLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(AppCoordinator coordinator) =>
      coordinator.settingsStack;

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => coordinator.tryPop()),
        title: const Text('Settings'),
      ),
      body: buildPath(coordinator),
    );
  }
}

// ============================================================================
// Tab Routes (belong to TabBarLayout - custom layout)
// ============================================================================

class FeedTabLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(AppCoordinator coordinator) =>
      coordinator.feedTabStack;

  @override
  Type get layout => TabBarLayout;
}

class FeedTab extends AppRoute {
  @override
  Type get layout => FeedTabLayout;

  @override
  Uri toUri() => Uri.parse('/home/tabs/feed');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Feed',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        _FeedItem(
          title: 'Post 1',
          onTap: () => coordinator.push(FeedDetail(id: '1')),
        ),
        _FeedItem(
          title: 'Post 2',
          onTap: () => coordinator.push(FeedDetail(id: '2')),
        ),
        _FeedItem(
          title: 'Post 3',
          onTap: () => coordinator.push(FeedDetail(id: '3')),
        ),
        _FeedItem(
          title: 'Post "profile" will redirect to ProfileDetail',
          onTap: () => coordinator.push(FeedDetail(id: 'profile')),
        ),
        const SizedBox(height: 24),
        const Text(
          'props demo — navigate() matches by props',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        _FeedItem(
          title: 'Order 5500 (props correct)',
          onTap: () => coordinator.navigate(OrderDetail(id: '5500')),
        ),
        _FeedItem(
          title: 'Order 8123 (props correct)',
          onTap: () => coordinator.navigate(OrderDetail(id: '8123')),
        ),
      ],
    );
  }
}

class ProfileTab extends AppRoute {
  @override
  Type get layout => TabBarLayout;

  @override
  Uri toUri() => Uri.parse('/home/tabs/profile');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Profile',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: () => coordinator.push(ProfileDetail()),
          child: const Text('View Profile Details'),
        ),
      ],
    );
  }
}

/// Carries data rather than being identified by it.
///
/// The tab list is fixed, so `/home/tabs/settings?section=privacy` is *the
/// settings tab*, not a second one. [RouteQueryParameters] is what says so:
/// queries stay out of the route's identity, so changing one updates the URL
/// instead of navigating somewhere, and the notifier redraws only the part that
/// reads it.
class SettingsTab extends AppRoute with RouteQueryParameters {
  SettingsTab({Map<String, String> queries = const {}})
    : queryNotifier = ValueNotifier(queries);

  @override
  final ValueNotifier<Map<String, String>> queryNotifier;

  String get section => query('section') ?? 'general';

  @override
  Type get layout => TabBarLayout;

  @override
  Uri toUri() => Uri(
    path: '/home/tabs/settings',
    queryParameters: queries.isEmpty ? null : queries,
  );

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    // The lazy demo's other half: with `lazy: true` this fires the first time
    // the tab is opened rather than at startup, and the query buttons below do
    // not fire it again — `selectorBuilder` redraws one line instead.
    log('build SettingsTab');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Quick Settings',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        // Only this line redraws when a button below changes the section — the
        // rest of the tab is left alone, along with anything it is holding.
        // Arriving by `navigate` rebuilds the tab as a whole instead.
        selectorBuilder<String>(
          selector: (queries) => queries['section'] ?? 'general',
          builder: (context, section) => Text(
            'section: $section',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final next in ['general', 'privacy', 'account'])
              OutlinedButton(
                onPressed: () =>
                    updateQueries(coordinator, queries: {'section': next}),
                child: Text(next),
              ),
          ],
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: () => coordinator.push(GeneralSettings()),
          child: const Text('Go to Full Settings'),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: () => coordinator.push(Login()),
          child: const Text('Go to Login'),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: () {
            coordinator.recoverRouteFromUri(Uri.parse('/home/feed/3221'));
          },
          child: const Text('Recover Route'),
        ),
      ],
    );
  }
}

// ============================================================================
// Detail Routes (belong to HomeLayout - navigatorStack layout)
// ============================================================================

/// Declares the stack it sits on through [deeplinkStack], so arriving here from
/// a cold link still leaves the feed underneath — and leaving it goes through
/// [popGuardWith] like any other pop.
class FeedDetail extends AppRoute
    with RouteGuard, RouteRedirect, RouteDeepLink {
  FeedDetail({required this.id});

  final String id;

  @override
  Type get layout => FeedTabLayout;

  @override
  DeeplinkStrategy get deeplinkStrategy => DeeplinkStrategy.stack;

  @override
  List<RouteUri> deeplinkStack(Uri uri) => [FeedTab(), this];

  @override
  Uri toUri() => Uri.parse('/home/feed/$id');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Feed Detail $id')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Feed Detail for Post $id',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => coordinator.pop(),
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  List<Object?> get props => [id];

  /// Showing confirm pop dialog
  @override
  FutureOr<bool> popGuardWith(AppCoordinator coordinator) async {
    final confirm = await showDialog<bool>(
      context: coordinator.navigator.context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm'),
        content: const Text('Are you sure you want to leave this page?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );

    return confirm ?? false;
  }

  @override
  AppRoute redirect() {
    /// Redirect to other stack demonstration
    /// The redirect path resolver by the Coordinator
    if (id == 'profile') return ProfileDetail();
    return this;
  }
}

class ProfileDetail extends AppRoute {
  @override
  Type get layout => HomeLayout;

  @override
  Uri toUri() => Uri.parse('/home/profile/detail');

  @override
  Widget build(
    covariant Coordinator<RouteUnique> coordinator,
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile Detail')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Profile Detail Page', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => coordinator.pop(),
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Settings Routes (belong to SettingsLayout - navigatorStack layout)
// ============================================================================

class GeneralSettings extends AppRoute {
  @override
  Type get layout => SettingsLayout;

  @override
  Uri toUri() => Uri.parse('/settings/general');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    resolveParentLayout(coordinator);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'General Settings',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        ListTile(
          title: Text('Account Settings'),
          onTap: () => coordinator.push(AccountSettings()),
        ),
        ListTile(
          title: Text('Privacy Settings'),
          onTap: () => coordinator.push(PrivacySettings()),
        ),
      ],
    );
  }
}

class AccountSettings extends AppRoute {
  @override
  Type get layout => SettingsLayout;

  @override
  Uri toUri() => Uri.parse('/settings/account');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return Material(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Account Settings',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const ListTile(title: Text('Email')),
          const ListTile(title: Text('Password')),
          const ListTile(title: Text('Delete Account')),
        ],
      ),
    );
  }
}

class PrivacySettings extends AppRoute {
  @override
  Type get layout => SettingsLayout;

  @override
  Uri toUri() => Uri.parse('/settings/privacy');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return Material(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Privacy Settings',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const ListTile(title: Text('Data Privacy')),
          const ListTile(title: Text('Location Services')),
          const ListTile(title: Text('Analytics')),
        ],
      ),
    );
  }
}

// ============================================================================
// Not Found Route
// ============================================================================

class NotFound extends AppRoute {
  NotFound({required this.uri});

  final Uri uri;

  @override
  Uri toUri() => Uri.parse('/not-found');

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Not Found')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text('Route not found: ${uri.path}'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => coordinator.replace(HomeLayout()),
              child: const Text('Go Home'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reached with `navigate`, which finds an existing entry by comparing `props`.
///
/// Try it: open Order 5500, then Order 8123 — or type the URLs directly. Now
/// comment out `props` below and repeat. Both orders compare equal, so
/// `navigate` matches the one already on the stack and you stay on 5500 while
/// the URL says 8123. Debug builds assert with an explanation instead of
/// leaving you to notice the wrong screen.
class OrderDetail extends AppRoute {
  OrderDetail({required this.id, this.note = 'none'});

  final String id;

  /// Data the route carries, not part of its identity — the order is still the
  /// same order whatever the note says.
  String note;

  @override
  Type get layout => HomeLayout;

  @override
  Uri toUri() => Uri.parse('/order/$id');

  // Remove this to see the failure the assert describes.
  @override
  List<Object?> get props => [id];

  /// Navigating to an order already on the stack hands the existing route the
  /// new data instead of pushing a second copy.
  @override
  void onUpdate(covariant OrderDetail newRoute) {
    super.onUpdate(newRoute);
    note = newRoute.note;
    debugPrint('OrderDetail($id).onUpdate -> note is now "$note"');
  }

  @override
  Widget build(AppCoordinator coordinator, BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Order $id')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Order $id', style: const TextStyle(fontSize: 32)),
            const SizedBox(height: 16),
            Text('Note: $note', style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                final stamp = DateTime.now().toIso8601String().substring(
                  11,
                  19,
                );
                coordinator.navigate(OrderDetail(id: id, note: stamp));
              },
              child: const Text('Update note'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              child: Text(
                'Navigating to an order already on the stack does not push a '
                'second copy: onUpdate hands the existing route the new note, '
                'and the page refreshes in place.',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Coordinator
// ============================================================================

class AppCoordinator extends Coordinator<AppRoute> with CoordinatorDebug {
  // Navigation paths for different shells
  late final NavigationPath<AppRoute> homeStack = NavigationPath.createWith(
    label: 'home',
    coordinator: this,
  )..bindLayout(HomeLayout.new);
  late final NavigationPath<AppRoute> settingsStack = NavigationPath.createWith(
    label: 'settings',
    coordinator: this,
  )..bindLayout(SettingsLayout.new);
  late final IndexedStackPath<AppRoute> tabIndexed =
      IndexedStackPath.createWith(coordinator: this, label: 'home-tabs', [
        FeedTabLayout(),
        ProfileTab(),
        SettingsTab(),
      ], lazy: true)..bindLayout(TabBarLayout.new);

  late final NavigationPath<AppRoute> feedTabStack = NavigationPath.createWith(
    label: 'feed-nested',
    coordinator: this,
  )..bindLayout(FeedTabLayout.new);

  @override
  List<StackPath> get paths => [
    ...super.paths,
    homeStack,
    settingsStack,
    tabIndexed,
    feedTabStack,
  ];

  @override
  List<AppRoute> get debugRoutes => [
    Login(),
    FeedTabLayout(),
    ProfileTab(),
    SettingsTab(),
    FeedDetail(id: '1'),
    ProfileDetail(),
    GeneralSettings(),
    AccountSettings(),
    PrivacySettings(),
    NotFound(uri: Uri.parse('/not-found')),
  ];

  @override
  AppRoute parseRouteFromUri(Uri uri) {
    return switch (uri.pathSegments) {
      // Root - default to feed tab (layouts will be set up automatically)
      [] => Login(),
      // Home routes - default to feed tab
      ['home'] => FeedTab(),
      ['home', 'tabs'] => FeedTab(), // Default to feed tab
      ['home', 'tabs', 'feed'] => FeedTab(),
      ['home', 'tabs', 'profile'] => ProfileTab(),
      ['home', 'tabs', 'settings'] => SettingsTab(queries: uri.queryParameters),
      ['home', 'feed', final id] => FeedDetail(id: id),
      ['home', 'profile', 'detail'] => ProfileDetail(),
      // Settings routes - default to general settings
      ['settings'] => GeneralSettings(),
      ['settings', 'general'] => GeneralSettings(),
      ['settings', 'account'] => AccountSettings(),
      ['settings', 'privacy'] => PrivacySettings(),
      ['login'] => Login(),
      ['order', final id] => OrderDetail(id: id),
      // Not found
      _ => NotFound(uri: uri),
    };
  }
}

class Login extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/login');

  @override
  Widget build(
    covariant Coordinator<RouteUnique> coordinator,
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => coordinator.tryPop()),
        title: const Text('Login'),
      ),
      body: Center(
        child: TextButton(
          onPressed: () => coordinator.replace(FeedTab()),
          child: Text('Go to Feed'),
        ),
      ),
    );
  }
}

class _FeedItem extends StatelessWidget {
  const _FeedItem({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(title),
        trailing: const Icon(Icons.arrow_forward),
        onTap: onTap,
      ),
    );
  }
}
