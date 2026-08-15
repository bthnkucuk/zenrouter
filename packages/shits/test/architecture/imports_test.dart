import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ============================================================================
// The geometry, physics and model layers are pure: they resolve detents,
// integrate simulations and apply layout corrections, and they do it without a
// binding. That is what lets every test above them run device-free, with the
// measured devices as `const` fixtures and no `pump` anywhere.
//
// It is an invariant one careless import destroys, and nothing about a passing
// suite would say so — the layer would simply start needing a binding, and the
// tests that did not yet would keep passing. So it is a test rather than a
// convention.
//
// Stated as an allow-list and not as a ban-list, because the interesting
// failure is the import nobody thought to ban: `package:flutter/animation.dart`
// carries `TickerProvider` in through `scheduler.dart` while reading like a
// harmless source of `Curves`, and a third-party package would be a dependency
// this one has deliberately gone without.
// ============================================================================

/// What a layer may reach for, and which layers it may sit on.
///
/// `model/` adds `foundation.dart` — `ChangeNotifier` and nothing else — to
/// what geometry and physics get. It does **not** add `scheduler.dart`, and
/// that is why `PanelModel` owns simulations rather than a `TickerProvider`:
/// DESIGN.md §2.4 gives it a vsync and §6 gives it this allowance, and only one
/// of the two can be true.
const _allowances = <String, ({Set<String> packages, Set<String> layers})>{
  'geometry': (
    packages: {
      'package:meta/meta.dart',
      'package:flutter/painting.dart',
      'package:flutter/physics.dart',
    },
    layers: {'geometry'},
  ),
  'physics': (
    packages: {
      'package:meta/meta.dart',
      'package:flutter/painting.dart',
      'package:flutter/physics.dart',
    },
    layers: {'geometry', 'physics'},
  ),
  // No `painting.dart`. Geometry needs it for `Axis`, `EdgeInsets` and
  // `TextDirection`; the model layer takes none of the three, and an allowance
  // wider than the layer uses is a door held open for the import nobody
  // thought to ban — which is the reason this test is an allow-list at all.
  'model': (
    packages: {
      'package:meta/meta.dart',
      'package:flutter/physics.dart',
      'package:flutter/foundation.dart',
    },
    layers: {'geometry', 'physics', 'model'},
  ),
};

/// The URI of an `import`/`export` directive, or null if the line is neither.
///
/// Pulled out of the quotes rather than matched against the whole line, so that
/// `show`, `hide` and `as` clauses do not have to be anticipated — `detent.dart`
/// already imports `painting.dart show Axis`.
String? _directiveUri(String line) {
  final trimmed = line.trimLeft();
  if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
    return null;
  }
  return RegExp(
    """^(?:import|export)\\s+['"]([^'"]+)['"]""",
  ).firstMatch(trimmed)?.group(1);
}

/// Which layer a relative [uri] written inside [layer] reaches into.
String _targetLayer(String uri, String layer) =>
    RegExp(r'\.\./(\w+)/').firstMatch(uri)?.group(1) ?? layer;

void main() {
  for (final MapEntry(key: layer, value: allowance) in _allowances.entries) {
    test('$layer imports only what its layer may', () {
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
          final uri = _directiveUri(line);
          if (uri == null || uri.startsWith('dart:')) continue;

          if (uri.startsWith('package:')) {
            if (!allowance.packages.contains(uri)) {
              offenders.add('${entity.path}: $uri');
            }
            continue;
          }

          final target = _targetLayer(uri, layer);
          if (!allowance.layers.contains(target)) {
            offenders.add('${entity.path}: $uri (reaches $target/)');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'a pure layer stopped being pure, or stopped being a layer. '
            '$layer/ may import ${allowance.packages.join(', ')} and the '
            'layers ${allowance.layers.join(', ')}.',
      );
    });
  }

  test('the layers are the ones this test claims to cover', () {
    // A fourth directory under `lib/src/` that is pure but unlisted would be
    // silently unguarded, and the widget layers are supposed to be there — so
    // this fails loudly and is amended deliberately rather than drifting.
    final present = Directory('lib/src')
        .listSync()
        .whereType<Directory>()
        .map((dir) => dir.uri.pathSegments[dir.uri.pathSegments.length - 2])
        .toSet();
    expect(
      present.difference(_allowances.keys.toSet()),
      isEmpty,
      reason:
          'a new layer under lib/src/ needs an allowance here, or a decision '
          'that it is one of the impure ones — render/, scroll/, widgets/ and '
          'route/ are, and go on the exception list when they land.',
    );
  });
}
