import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter_core/src/internal/reactive.dart';

void main() {
  group('ListenableMixin.merge', () {
    test('ignores null entries', () {
      final a = _RecordingListenable('a');
      final merged = ListenableMixin.merge([null, a, null]);

      var notified = 0;
      merged.addListener(() => notified++);
      a.notify();
      expect(notified, 1);
    });

    test('notifies when any child notifies', () {
      final a = _RecordingListenable('a');
      final b = _RecordingListenable('b');
      final merged = ListenableMixin.merge([a, b]);

      var notified = 0;
      merged.addListener(() => notified++);

      a.notify();
      expect(notified, 1);
      b.notify();
      expect(notified, 2);
    });

    test('addListener registers on every child', () {
      final a = _RecordingListenable('a');
      final b = _RecordingListenable('b');
      final merged = ListenableMixin.merge([a, b]);

      void listener() {}
      merged.addListener(listener);

      expect(a.listeners, contains(listener));
      expect(b.listeners, contains(listener));
    });

    test('removeListener unregisters from every child', () {
      final a = _RecordingListenable('a');
      final b = _RecordingListenable('b');
      final merged = ListenableMixin.merge([a, b]);

      void listener() {}
      merged.addListener(listener);
      merged.removeListener(listener);

      expect(a.listeners, isEmpty);
      expect(b.listeners, isEmpty);
    });

    test('empty merge accepts listeners without notifying', () {
      final merged = ListenableMixin.merge(const <ListenableMixin?>[]);
      var notified = 0;
      merged.addListener(() => notified++);
      merged.removeListener(() => notified++);
      expect(notified, 0);
    });

    test('all-null merge behaves like empty', () {
      final merged = ListenableMixin.merge([null, null]);
      var notified = 0;
      void listener() => notified++;
      merged.addListener(listener);
      merged.removeListener(listener);
      expect(notified, 0);
    });

    test('toString lists children', () {
      final a = _RecordingListenable('a');
      final b = _RecordingListenable('b');
      final merged = ListenableMixin.merge([a, b]);

      expect(
        merged.toString(),
        'ListenableMixin.merge([_RecordingListenable(a), _RecordingListenable(b)])',
      );
    });

    test('toString for empty merge', () {
      expect(
        ListenableMixin.merge(const <ListenableMixin?>[]).toString(),
        'ListenableMixin.merge([])',
      );
    });

    test('snapshot is fixed after creation', () {
      final a = _RecordingListenable('a');
      final children = <ListenableMixin?>[a];
      final merged = ListenableMixin.merge(children);

      // Mutating the source iterable after merge must not affect listeners.
      children.add(_RecordingListenable('late'));

      var notified = 0;
      merged.addListener(() => notified++);
      a.notify();
      expect(notified, 1);
      expect(a.listeners, hasLength(1));
    });
  });

  group('ListenableObject', () {
    test('dispose is callable and mustCallSuper-safe', () {
      final object = _TestListenableObject();
      expect(object.disposed, isFalse);
      object.dispose();
      expect(object.disposed, isTrue);
    });

    test('implements ListenableMixin', () {
      final object = _TestListenableObject();
      expect(object, isA<ListenableMixin>());

      var notified = 0;
      object.addListener(() => notified++);
      object.notifyListeners();
      expect(notified, 1);

      object.removeListener(object.listeners.single);
      object.notifyListeners();
      expect(notified, 1);
    });
  });
}

class _RecordingListenable implements ListenableMixin {
  _RecordingListenable(this.label);

  final String label;
  final listeners = <VoidCallback>[];

  @override
  void addListener(VoidCallback listener) => listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);

  void notify() {
    for (final listener in List<VoidCallback>.of(listeners)) {
      listener();
    }
  }

  @override
  String toString() => '_RecordingListenable($label)';
}

class _TestListenableObject with ListenableObject {
  final listeners = <VoidCallback>[];
  bool disposed = false;

  @override
  void addListener(VoidCallback listener) => listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);

  @override
  void notifyListeners() {
    for (final listener in List<VoidCallback>.of(listeners)) {
      listener();
    }
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
