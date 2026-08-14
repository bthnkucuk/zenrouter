import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ============================================================================
// The geometry and physics layers are pure: they resolve detents and integrate
// simulations, and they do it without a binding. That is what lets every test
// above them run device-free, with the measured devices as `const` fixtures.
//
// It is an invariant one careless import destroys, and nothing about a passing
// suite would say so — the layer would simply start needing a binding, and the
// tests that did not yet would keep passing. So it is a test rather than a
// convention.
// ============================================================================

/// Imports that would drag in `WidgetsBinding`.
const _forbidden = [
  'package:flutter/widgets.dart',
  'package:flutter/material.dart',
  'package:flutter/cupertino.dart',
  'package:flutter/services.dart',
  'package:flutter/scheduler.dart',
  'package:flutter/rendering.dart',
  'package:flutter/gestures.dart',
  'package:flutter_test/',
];

void main() {
  for (final layer in ['geometry', 'physics']) {
    test('$layer imports no binding', () {
      final dir = Directory('lib/src/$layer');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'run from the package root, not the workspace root',
      );

      final offenders = <String>[];
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final line in entity.readAsLinesSync()) {
          final trimmed = line.trimLeft();
          if (!trimmed.startsWith('import ') &&
              !trimmed.startsWith('export ')) {
            continue;
          }
          for (final banned in _forbidden) {
            if (trimmed.contains(banned)) {
              offenders.add('${entity.path}: $trimmed');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'a pure layer stopped being pure. `painting.dart` and `physics.dart` '
            'are allowed and carry no binding; the list above does.',
      );
    });
  }
}
