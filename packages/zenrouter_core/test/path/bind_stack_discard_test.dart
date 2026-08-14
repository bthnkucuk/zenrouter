// Setting a stack wholesale is exactly what this file is about, and it is
// protected on StackPath — so the check is silenced here rather than worked
// around.
// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/zenrouter_core.dart';

// ============================================================================
// Replacing a path's whole stack dropped the routes that were on it without
// telling them: no `onDiscard`, and still bound to a path they were no longer
// on. `clear` keeps that contract and `applyStack` kept it by hand; the
// primitive under both did not, which is how restoration lost it.
// ============================================================================

class Leaf extends RouteUri {
  Leaf(this.id);
  final int id;
  int discards = 0;

  @override
  List<Object?> get props => [id];

  @override
  Uri get identifier => toUri();

  @override
  Uri toUri() => Uri.parse('/leaf/$id');

  @override
  Object? get parentLayoutKey => null;

  @override
  void onDiscard() {
    discards++;
    super.onDiscard();
  }
}

class TestPath extends StackPath<Leaf> {
  TestPath() : super(<Leaf>[]);

  final _listeners = <void Function()>[];

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void notifyListeners() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  @override
  Leaf? get activeRoute => stack.lastOrNull;

  @override
  PathKey get pathKey => const PathKey('test');

  @override
  void reset() => clear();

  @override
  Future<void> activateRoute(Leaf route) async => bindStack([...stack, route]);
}

void main() {
  late TestPath path;

  setUp(() => path = TestPath());

  test('a route left out of the new stack is discarded and unbound', () {
    final dropped = Leaf(1);
    path.bindStack([dropped]);

    path.bindStack([Leaf(2)]);

    expect(dropped.discards, 1);
    expect(dropped.stackPath, isNull);
  });

  test('a route carried over is left alone', () {
    final kept = Leaf(1);
    path.bindStack([kept]);

    path.bindStack([kept, Leaf(2)]);

    expect(kept.discards, 0);
    expect(kept.stackPath, same(path));
  });

  test('identity decides, not equality', () {
    // Two equal routes are two entries. The one being replaced is leaving even
    // though something `==` to it takes its place, and it is the instance the
    // widget layer is holding.
    final first = Leaf(1);
    final second = Leaf(1);
    expect(first, second);
    path.bindStack([first]);

    path.bindStack([second]);

    expect(first.discards, 1);
    expect(first.stackPath, isNull);
    expect(second.discards, 0);
    expect(second.stackPath, same(path));
  });

  test('emptying the stack discards everything on it', () {
    final a = Leaf(1);
    final b = Leaf(2);
    path.bindStack([a, b]);

    path.bindStack([]);

    expect([a.discards, b.discards], [1, 1]);
    expect(path.stack, isEmpty);
  });
}
