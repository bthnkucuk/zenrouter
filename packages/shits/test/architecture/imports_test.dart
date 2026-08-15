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
  // The first impure layer, and the allowance is two packages rather than one
  // because the layer is two halves. The render object needs `rendering.dart`
  // and nothing wider; the widget that installs it cannot be written without
  // `widgets.dart`, which is a superset of `rendering.dart` and would cover the
  // whole directory if the allowance stopped here. `_widgetFreeFiles` below is
  // what keeps it from doing that.
  'render': (
    packages: {
      'package:meta/meta.dart',
      'package:flutter/rendering.dart',
      'package:flutter/widgets.dart',
    },
    layers: {'geometry', 'physics', 'model', 'render'},
  ),
  // **Not `render`.** The scroll layer talks to the `PanelModel`, never to the
  // render object: the arbiter reads detents and writes an extent, and the box
  // hears about it the way every other listener does. An allowance that let
  // `scroll/` name `RenderPanelViewport` is how "the panel resizes without the
  // widget tree hearing about it" becomes "…except when a list is being
  // dragged", and the two layers would then have to be built in one order.
  //
  // `gestures.dart` is here because `Drag` and `DragUpdateDetails` are the
  // interface a `ScrollPosition` hands back to a recogniser, and `widgets.dart`
  // — unlike `rendering.dart` — does not re-export them. `scheduler.dart` is
  // the fused fling's one `Ticker`.
  //
  // `rendering.dart` is here for exactly one name, and it grants nothing this
  // layer did not already have: `widgets.dart` is built on top of it, so every
  // symbol was already reachable — it re-exports `rendering.dart` for
  // `TextSelectionHandleType` and nothing else. `ScrollDirection` is the one
  // `position.dart` needs, because `ScrollPosition.updateUserScrollDirection`
  // takes one and a subclass that cannot name it cannot publish a direction.
  // It is imported `show ScrollDirection`, which is the narrower guard this
  // row cannot express.
  'scroll': (
    packages: {
      'package:meta/meta.dart',
      'package:flutter/physics.dart',
      'package:flutter/gestures.dart',
      'package:flutter/rendering.dart',
      'package:flutter/scheduler.dart',
      'package:flutter/widgets.dart',
    },
    layers: {'geometry', 'physics', 'model', 'scroll'},
  ),
};

/// Files that may not reach `package:flutter/widgets.dart`, and why each one
/// would stop being what it is if it did.
///
/// An allow-list per layer is too coarse for `render/`: the layer needs
/// `widgets.dart` for exactly one file, and granting it to the layer grants it
/// to the render object as well. The whole claim of the render layer is that a
/// panel resizes without the widget tree hearing about it — a claim about what
/// the render object *cannot reach*, not about what it happens to call today —
/// and `BuildContext` in scope is where someone puts a `setState`.
///
/// Note that `widgets.dart` exports `rendering.dart`, so a file that took the
/// wider import would still compile and still pass the layer check above. That
/// is precisely why this list is separate: the failure is invisible to the
/// coarser test.
///
/// The two `scroll/` entries are here for a different reason from the render
/// object's, and it is worth stating because it is a reason with an expiry date.
/// DESIGN.md §6 files `fused_axis.dart` and `fused_simulation.dart` under
/// `physics/`, which may import no binding at all; they are in `scroll/` only
/// because `physics/` was committed before this slice and this slice does not
/// own it. Keeping them unable to reach a `BuildContext` is the closest this
/// directory can come to the allowance they are supposed to live under, and it
/// is what makes moving them later a `git mv` and one row here rather than an
/// unpicking. Both are pure maths over `geometry/`: a `FusedAxis` is two spans
/// and a seam, and a `FusedSimulation` is friction then a spring.
const _widgetFreeFiles = <String>{
  'lib/src/render/render_panel.dart',
  'lib/src/physics/fused_axis.dart',
  'lib/src/physics/fused_simulation.dart',
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

  for (final path in _widgetFreeFiles) {
    test('$path cannot see a BuildContext', () {
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'run from the package root, not the workspace root',
      );
      final offenders = [
        for (final line in file.readAsLinesSync())
          if (_directiveUri(line)
              case 'package:flutter/widgets.dart' ||
                  'package:flutter/material.dart' ||
                  'package:flutter/cupertino.dart')
            line.trim(),
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'the render object is the half of this layer that is supposed to be '
            'unreachable from a build. It gets rendering.dart; the widget next '
            'to it gets widgets.dart.',
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
