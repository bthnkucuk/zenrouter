import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Test Routes
// ============================================================================

abstract class AppRoute extends RouteTarget with RouteUnique {}

/// Parameterised, but `props` omits the id — the mistake the assert exists for.
class UnderSpecified extends AppRoute {
  UnderSpecified(this.id);
  final String id;

  @override
  Uri toUri() => Uri.parse('/order/$id');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Placeholder();
}

/// The same route with identity in `props`.
class WellSpecified extends AppRoute {
  WellSpecified(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/order/$id');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Placeholder();
}

/// `props` carries per-instance state, so two identical destinations compare
/// unequal — the mirror mistake.
class OverSpecified extends AppRoute {
  OverSpecified() : _token = Object();
  final Object _token;

  @override
  List<Object?> get props => [_token];

  @override
  Uri toUri() => Uri.parse('/feed');

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Placeholder();
}

/// Identity is the path; queries ride along and change in place.
class Searchable extends AppRoute with RouteQueryParameters {
  Searchable({Map<String, String>? queries}) {
    queryNotifier.value = queries ?? {};
  }

  @override
  final ValueNotifier<Map<String, String>> queryNotifier = ValueNotifier({});

  @override
  Uri toUri() => Uri(path: '/search', queryParameters: queries);

  @override
  Widget build(covariant Coordinator coordinator, BuildContext context) =>
      const Placeholder();
}

void unawaited(Future<void> f) {}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('props must identify the destination', () {
    test('navigate onto an under-specified route asserts', () async {
      final path = NavigationPath<AppRoute>.create();
      unawaited(path.push(UnderSpecified('5500')));
      await settle();

      await expectLater(
        () => path.navigate(UnderSpecified('8123')),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(
              contains('/order/8123'),
              contains('/order/5500'),
              contains('props'),
            ),
          ),
        ),
      );
    });

    test('pushOrMoveToTop onto an under-specified route asserts', () async {
      final path = NavigationPath<AppRoute>.create();
      unawaited(path.push(UnderSpecified('5500')));
      await settle();

      await expectLater(
        () => path.pushOrMoveToTop(UnderSpecified('8123')),
        throwsA(isA<AssertionError>()),
      );
    });

    test('an over-specified route asserts on the duplicate it would push',
        () async {
      final path = NavigationPath<AppRoute>.create();
      unawaited(path.pushOrMoveToTop(OverSpecified()));
      await settle();

      await expectLater(
        () => path.pushOrMoveToTop(OverSpecified()),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('/feed'), contains('per '), contains('props')),
          ),
        ),
      );
    });

    test('a well-specified route navigates to the right entry', () async {
      final path = NavigationPath<AppRoute>.create();
      unawaited(path.push(WellSpecified('5500')));
      await settle();
      unawaited(path.push(WellSpecified('8123')));
      await settle();

      await path.navigate(WellSpecified('5500'));
      await settle();

      final top = path.stack.last as WellSpecified;
      expect(top.id, '5500');
      expect(path.stack.length, 1);
    });

    test('query-only differences are not a mistake', () async {
      final path = NavigationPath<AppRoute>.create();
      final listing = Searchable(queries: {'q': 'boots'});
      unawaited(path.push(listing));
      await settle();

      // Same destination, different query — RouteQueryParameters exists for
      // exactly this, so the match must be allowed and updated in place.
      await expectLater(
        path.navigate(Searchable(queries: {'q': 'sandals'})),
        completes,
      );
      expect(path.stack.length, 1);
      expect(identical(path.stack.single, listing), isTrue);
    });
  });
}
