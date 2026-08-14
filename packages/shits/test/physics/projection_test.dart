import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/physics/projection.dart';

/// The closed form of `FrictionSimulation.finalX` at zero constant
/// deceleration: `x − v/ln(drag)`.
///
/// Written out here so that the implementation can be replaced by it — the
/// simulation object is ten Newton iterations and an allocation for one
/// multiply — without anyone having to re-derive whether that is safe.
double _closedForm(double from, double velocity) =>
    from - velocity / math.log(kDecelerationDrag);

/// Every `.dart` file under `lib/`, with comment lines removed.
///
/// The comments are stripped because [kDecelerationDrag]'s own documentation
/// names the wrong constants in order to warn against them, and a test that
/// could not tell a warning from a use would force the warning to be deleted.
Iterable<(String, String)> _sourceCode() sync* {
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    fail(
      'Run this from the package root; there is no lib/ at ${Directory.current.path}.',
    );
  }
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final code = entity
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    yield (entity.path, code);
  }
}

void main() {
  group('the deceleration is iOS\'s', () {
    test('a 1000 px/s fling travels 499.38pt', () {
      // UIScrollViewDecelerationRateNormal is 0.998 per millisecond, and
      // 0.998^1000 is about 0.135. The landing distance that falls out is
      // 0.49938 x velocity, which is UIKit to four significant figures.
      expect(kDecelerationDrag, 0.135);
      expect(projectLanding(0, 1000), closeTo(499.38, 0.05));
    });

    test('the simulation agrees with its own closed form', () {
      for (final from in const [0.0, 214.0, 778.0, -90.0]) {
        for (final v in const [0.0, 1.0, 400.0, -3000.0, 12000.0]) {
          expect(
            projectLanding(from, v),
            moreOrLessEquals(_closedForm(from, v), epsilon: 1e-9),
            reason: 'from $from at $v px/s',
          );
        }
      }
    });

    test('no velocity, no travel', () {
      expect(projectLanding(214, 0), 214.0);
    });

    test('the two directions are mirror images', () {
      expect(projectLanding(0, -1000), -projectLanding(0, 1000));
      expect(
        projectLanding(500, -1000),
        moreOrLessEquals(1000 - projectLanding(500, 1000), epsilon: 1e-9),
      );
    });

    test('the projection is linear in velocity and in the start', () {
      // Which is why a snap decision can be made once, at release, instead of
      // being re-derived per frame against a moving position.
      expect(
        projectLanding(0, 2000) - projectLanding(0, 1000),
        moreOrLessEquals(projectLanding(0, 1000), epsilon: 1e-9),
      );
      expect(
        projectLanding(300, 1000) - projectLanding(0, 1000),
        moreOrLessEquals(300, epsilon: 1e-9),
      );
    });

    test('the fused axis projects with the same constant', () {
      // Two call sites with the same literal in them is how a fling lands in one
      // place and snaps to another.
      expect(
        projectFusedLanding(const FusedPosition(120), 1000).px,
        projectLanding(120, 1000),
      );
    });
  });

  group('the lineage is not Android\'s', () {
    test('0.322 appears in no line of code', () {
      for (final (path, code) in _sourceCode()) {
        expect(
          code.contains('0.322'),
          isFalse,
          reason:
              '$path uses 0.322. That is not the iOS deceleration; '
              'kDecelerationDrag is 0.135.',
        );
      }
    });

    test('ClampingScrollSimulation is not reachable from lib/', () {
      for (final (path, code) in _sourceCode()) {
        expect(
          code.contains('ClampingScrollSimulation'),
          isFalse,
          reason: '$path reaches for Android\'s fling spline.',
        );
      }
    });

    test('and the grep is actually reading something', () {
      // Without this, deleting lib/ would make both tests above pass.
      final sources = _sourceCode().toList();
      expect(sources, isNotEmpty);
      expect(
        sources.any((s) => s.$2.contains('kDecelerationDrag = 0.135')),
        isTrue,
      );
    });
  });
}
