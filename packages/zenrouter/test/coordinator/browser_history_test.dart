import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenrouter/zenrouter.dart';

// ============================================================================
// Test Routes
// ============================================================================

class AppRoute extends RouteTarget with RouteUnique {
  AppRoute(this.id);
  final String id;

  @override
  List<Object?> get props => [id];

  @override
  Uri toUri() => Uri.parse('/$id');

  @override
  Widget build(Coordinator coordinator, BuildContext context) =>
      Scaffold(body: Text(id));
}

class TestCoordinator extends Coordinator<AppRoute> {
  @override
  AppRoute parseRouteFromUri(Uri uri) =>
      AppRoute(uri.pathSegments.isEmpty ? 'home' : uri.pathSegments.first);
}

void unawaited(Future<void> f) {}

/// Records what the framework tells the browser: the URI, and whether it
/// overwrites the current history entry or adds a new one.
class HistoryRecorder {
  final entries = <({String uri, bool replace})>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (call) async {
        if (call.method == 'routeInformationUpdated') {
          final args = (call.arguments as Map).cast<String, Object?>();
          entries.add((
            uri: args['uri']! as String,
            replace: args['replace'] == true,
          ));
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        null,
      ),
    );
  }

  List<String> get pushed =>
      [for (final e in entries) if (!e.replace) e.uri];

  void clear() => entries.clear();
}

Future<TestCoordinator> pumpApp(
  WidgetTester tester,
  HistoryRecorder recorder,
) async {
  recorder.install(tester);
  final c = TestCoordinator();
  await tester.pumpWidget(MaterialApp.router(routerConfig: c));
  await tester.pumpAndSettle();
  recorder.clear();
  return c;
}

void main() {
  group('Browser history entries', () {
    testWidgets('push adds an entry', (tester) async {
      final rec = HistoryRecorder();
      final c = await pumpApp(tester, rec);

      unawaited(c.push(AppRoute('list')));
      await tester.pumpAndSettle();

      expect(rec.pushed, ['/list'], reason: 'forward navigation is a new entry');
    });

    testWidgets('replace overwrites instead of adding', (tester) async {
      final rec = HistoryRecorder();
      final c = await pumpApp(tester, rec);

      unawaited(c.push(AppRoute('login')));
      await tester.pumpAndSettle();
      rec.clear();

      // Signing in: the stack is reset, so /login must not stay reachable.
      await c.replace(AppRoute('feed'));
      await tester.pumpAndSettle();

      expect(rec.entries, isNotEmpty, reason: 'the new URI must be reported');
      expect(
        rec.pushed,
        isEmpty,
        reason: 'replace discarded the old stack; back must not resurrect it',
      );
    });

    testWidgets('pushReplacement leaves no entry behind', (tester) async {
      final rec = HistoryRecorder();
      final c = await pumpApp(tester, rec);

      unawaited(c.push(AppRoute('list')));
      await tester.pumpAndSettle();
      unawaited(c.push(AppRoute('detail')));
      await tester.pumpAndSettle();
      rec.clear();

      unawaited(c.root.pushReplacement(AppRoute('editor')));
      await tester.pumpAndSettle();

      expect(
        rec.pushed,
        isEmpty,
        reason: 'neither the replaced route nor the transient intermediate '
            'state may add an entry',
      );
      expect(
        rec.entries.last.uri,
        '/editor',
        reason: 'the replacement is what the browser ends on',
      );
    });

    testWidgets('an ordinary push after a replace still adds an entry', (
      tester,
    ) async {
      final rec = HistoryRecorder();
      final c = await pumpApp(tester, rec);

      await c.replace(AppRoute('feed'));
      await tester.pumpAndSettle();
      rec.clear();

      unawaited(c.push(AppRoute('article')));
      await tester.pumpAndSettle();

      expect(
        rec.pushed,
        ['/article'],
        reason: 'the replace intent must not leak into the next navigation',
      );
    });
  });

  group('replacesHistoryEntry flag', () {
    test('push clears it, pushReplacement sets it', () async {
      final c = TestCoordinator();
      addTearDown(c.dispose);

      unawaited(c.root.push(AppRoute('a')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.replacesHistoryEntry, isFalse);

      unawaited(c.root.pushReplacement(AppRoute('b')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.replacesHistoryEntry, isTrue);

      unawaited(c.root.push(AppRoute('c')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        c.replacesHistoryEntry,
        isFalse,
        reason: 'every commit writes the flag, so it never goes stale',
      );
    });

    test('pop clears it', () async {
      final c = TestCoordinator();
      addTearDown(c.dispose);

      unawaited(c.root.push(AppRoute('a')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      unawaited(c.root.pushReplacement(AppRoute('b')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.replacesHistoryEntry, isTrue);

      await c.root.pop();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.replacesHistoryEntry, isFalse);
    });
  });
}
