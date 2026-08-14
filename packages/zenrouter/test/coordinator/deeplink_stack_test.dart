import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// A URI can imply more than one screen: `/products/42` means a detail sitting
// on a list. Without saying so, a cold start lands on the detail alone and the
// back button leaves the app. A route says what it sits on through
// [DeeplinkStrategy.stack].
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

class ProductList extends AppRoute {
  @override
  Uri toUri() => Uri.parse('/products');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('list'));
}

class ProductDetail extends AppRoute with RouteDeepLink {
  ProductDetail(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/products/$id');

  @override
  DeeplinkStrategy get deeplinkStrategy => DeeplinkStrategy.stack;

  @override
  List<RouteUri> deeplinkStack(Uri uri) => [ProductList(), this];

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('detail-$id'));
}

class StackCoordinator extends Coordinator<AppRoute> {
  StackCoordinator({super.initialRoutePath});

  @override
  AppRoute parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['products', final id] => ProductDetail(id),
    _ => ProductList(),
  };
}

/// A route that declares nothing, so the single-route path applies.
class PlainDetail extends AppRoute {
  PlainDetail(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/plain/$id');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('plain-$id'));
}

class SingleCoordinator extends Coordinator<AppRoute> {
  SingleCoordinator({super.initialRoutePath});

  @override
  AppRoute parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['plain', final id] => PlainDetail(id),
    _ => ProductList(),
  };
}

// A layout, to check the synthesised entries still resolve their parents.
class ShopLayout extends AppRoute with RouteLayout<AppRoute> {
  @override
  NavigationPath<AppRoute> resolvePath(covariant LayoutCoordinator c) => c.shop;

  @override
  Uri toUri() => Uri.parse('/shop');

  @override
  Widget build(covariant LayoutCoordinator c, BuildContext context) =>
      Scaffold(body: buildPath(c));
}

class ShopList extends AppRoute {
  @override
  Type get layout => ShopLayout;

  @override
  Uri toUri() => Uri.parse('/shop/products');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      const Scaffold(body: Text('shoplist'));
}

class ShopDetail extends AppRoute with RouteDeepLink {
  ShopDetail(this.id);
  final String id;

  @override
  DeeplinkStrategy get deeplinkStrategy => DeeplinkStrategy.stack;

  @override
  List<RouteUri> deeplinkStack(Uri uri) => [ShopList(), this];

  @override
  Type get layout => ShopLayout;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/shop/products/$id');

  @override
  Widget build(covariant Coordinator c, BuildContext context) =>
      Scaffold(body: Text('shopdetail-$id'));
}

class LayoutCoordinator extends Coordinator<AppRoute> {
  LayoutCoordinator({super.initialRoutePath});

  late final NavigationPath<AppRoute> shop = NavigationPath.createWith(
    label: 'shop',
    coordinator: this,
  )..bindLayout(ShopLayout.new);

  @override
  List<StackPath> get paths => [...super.paths, shop];

  @override
  AppRoute parseRouteFromUri(Uri uri) => switch (uri.pathSegments) {
    ['shop', 'products', final id] => ShopDetail(id),
    _ => ShopList(),
  };
}

void main() {
  group('A URI can name a whole stack', () {
    testWidgets('cold start leaves something to go back to', (tester) async {
      final c = StackCoordinator(initialRoutePath: Uri.parse('/products/42'));
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      expect(
        c.root.stack.map((r) => r.toUri().path),
        ['/products', '/products/42'],
        reason: 'the list the URI implies must be underneath the detail',
      );
      expect(find.text('detail-42'), findsOneWidget);
    });

    testWidgets('and back actually goes to it', (tester) async {
      final c = StackCoordinator(initialRoutePath: Uri.parse('/products/42'));
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      await c.pop();
      await tester.pumpAndSettle();

      expect(find.text('list'), findsOneWidget);
    });

    testWidgets('a later deep link replaces the stack it names', (
      tester,
    ) async {
      final c = StackCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      await c.routerDelegate.setNewRoutePath(Uri.parse('/products/7'));
      await tester.pumpAndSettle();

      expect(c.root.stack.map((r) => r.toUri().path), [
        '/products',
        '/products/7',
      ]);
    });

    testWidgets('synthesised entries still get their layout', (tester) async {
      final c = LayoutCoordinator(
        initialRoutePath: Uri.parse('/shop/products/42'),
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      expect(
        c.shop.stack.map((r) => r.toUri().path),
        ['/shop/products', '/shop/products/42'],
        reason: 'both entries belong to the layout the URI implies',
      );
      expect(c.root.stack.whereType<ShopLayout>().length, 1);
    });
  });

  group('Saying nothing keeps the old behaviour', () {
    testWidgets('a route without the mixin is unchanged', (tester) async {
      final c = SingleCoordinator(initialRoutePath: Uri.parse('/plain/42'));
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      expect(
        c.root.stack.map((r) => r.toUri().path),
        ['/plain/42'],
        reason: 'nothing is synthesised underneath it',
      );
    });

    testWidgets('a URI naming a single screen lands on it alone', (
      tester,
    ) async {
      final c = StackCoordinator();
      await tester.pumpWidget(MaterialApp.router(routerConfig: c));
      await tester.pumpAndSettle();

      await c.routerDelegate.setNewRoutePath(Uri.parse('/products'));
      await tester.pumpAndSettle();

      expect(c.root.stack.map((r) => r.toUri().path), ['/products']);
    });
  });
}
