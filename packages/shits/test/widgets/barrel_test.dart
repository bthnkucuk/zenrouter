import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/shits.dart';

// ============================================================================
// `lib/shits.dart` is the package's only export surface (DESIGN.md §6), which
// makes it a decision rather than a list — and a decision nothing checks
// drifts. Two things are checked here and they fail in opposite directions.
//
// **Every export names its symbols.** A bare `export 'src/...'` re-exports
// whatever that file happens to contain *today*, so the front door widens
// silently the next time someone adds a class to `units.dart`. With `show`, the
// surface is one reviewable list in one file and widening it is a diff.
//
// **And the machine stays behind it.** The deny-list below is not a style rule:
// `PanelModel` is a mutable object with a commit protocol whose two halves must
// be called in one order from inside a layout pass, and handing it out turns
// every invariant in `model/` into a documentation request. It is also the
// export that would happen by accident, because `PanelViewport` takes one and
// `PanelConfig` sits in the same file as `kResnapWindow`, which is exported.
//
// The third test is the other direction and it is the compiler's: this file
// imports the barrel and nothing else, so a name that stopped being exported
// stops compiling here rather than in an app.
// ============================================================================

/// What must not be reachable through the front door, and what each one would
/// cost.
const _behindTheDoor = <String, String>{
  'PanelModel':
      'the machine: a mutable model with a two-call commit protocol run from '
      'inside a layout pass',
  'PanelConfig': 'the model\'s value type; Panel\'s arguments are the API',
  'PanelActivity': 'what the panel is doing is PanelMetrics\' job to describe',
  'LayoutCorrection': 'the dry/commit protocol, which has exactly one caller',
  'PanelViewport': 'takes a PanelModel, so exporting it exports the model',
  'RenderPanelViewport': 'the render object; reachable only through a panel',
  'PanelMedia': 'the render layer\'s half of a layout pass',
  'PanelScrollLink': 'the arbiter; every knob on it is already a policy',
  'PanelScrollPosition': 'created by the controller, never by an app',
  'PanelScrollBehavior': 'the coverage backstop, installed by the panel',
  'PanelScrollPhysics': 'the escape detector, installed by the behaviour',
  'PanelScrollAttachment':
      'installed by the panel; there is nothing to pass it',
  'PanelScrollSplit': 'an arbitration result, not a configuration',
  'PanelScrollDriver': 'the three scalars the arbiter may know about a list',
  'FusedAxis': 'the fused coordinate space',
  'FusedSimulation': 'one fling across two things',
  'FusedPosition': 'a coordinate on it, and @internal for that reason',
  'RubberBand': 'reached through PanelConfig.bandResistance and nowhere else',
  'SnapDecision': 'what snapTarget answers; SnapPolicy is the public end',
  'PanelDragMechanics': 'the accumulated position behind a gesture',
};

/// Every `export` directive in the barrel, as `(uri, shown names)`.
///
/// Parsed rather than reflected, because the thing under test is the *source*:
/// a missing `show` is invisible to anything that only looks at the resulting
/// namespace, since the names it lets through are real names that really are
/// exported.
List<({String uri, List<String>? show})> _exports() {
  final file = File('lib/shits.dart');
  expect(
    file.existsSync(),
    isTrue,
    reason: 'run from the package root, not the workspace root',
  );

  final source = file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  return [
    for (final directive in source.split(';'))
      if (directive.contains('export '))
        (
          uri: RegExp("""['"]([^'"]+)['"]""").firstMatch(directive)!.group(1)!,
          show: switch (RegExp(r'show\s+([\s\S]+)').firstMatch(directive)) {
            null => null,
            final match => [
              for (final name in match.group(1)!.split(','))
                if (name.trim().isNotEmpty) name.trim(),
            ],
          },
        ),
  ];
}

void main() {
  test('every export names what it lets through', () {
    final exports = _exports();
    expect(exports, isNotEmpty, reason: 'the barrel exports nothing at all');
    expect(
      [
        for (final e in exports)
          if (e.show == null) e.uri,
      ],
      isEmpty,
      reason:
          'a bare export re-exports whatever that file contains today, so the '
          'front door widens the next time somebody adds a class to it',
    );
  });

  test('and the machine stays behind it', () {
    final shown = {for (final e in _exports()) ...?e.show};
    for (final MapEntry(key: name, value: why) in _behindTheDoor.entries) {
      expect(shown, isNot(contains(name)), reason: '$name is $why');
    }
  });

  test('the names the design promises are on it', () {
    // The compiler runs this one: this file imports `package:shits/shits.dart`
    // and nothing else from the package, so a name that stopped being exported
    // stops the file compiling.
    expect(
      const Panel(
        detents: DetentSet([
          Detent.height(DetentValue(180)),
          Detent.medium,
          Detent.full,
        ]),
        initialDetent: Detent.medium,
        anchor: PanelAnchor.bottom,
        attachment: EdgeAttachment.edgeAttached,
        sizing: PanelSizing.resize,
        motion: PanelMotion.smooth(),
        snapPolicy: SnapPolicy.projected,
        resnapWindow: kResnapWindow,
        bandResistance: kPanelBandResistance,
        scrollPolicy: PanelScrollPolicy.resizesFromEdge,
        refreshPolicy: PanelRefreshPolicy.whenFullyOpen,
        momentumCarry: MomentumCarry.both,
        child: SizedBox(),
      ),
      isA<Widget>(),
    );
    expect(
      const PanelContentScaffold(
        body: SizedBox(),
        bottomBar: SizedBox(),
        bottomBarVisibility: BottomBarVisibility.natural(),
      ),
      isA<Widget>(),
    );
    expect(const PanelMediaQuery(child: SizedBox()), isA<Widget>());
    // Constructed and typed, never *called*: this test is about the door and
    // stays green while everything behind it is still a signature.
    expect(PanelController(), isA<Listenable>());
    expect(
      const Detent.fraction(Fraction(0.5)),
      isNot(const Detent.fraction(Fraction(0.6))),
    );
    // The one piece of the arbiter an author is ever told to name — the escape
    // error's own two-word fix, which has to be a fix a caller can write.
    expect(
      PanelScrollController,
      isNotNull,
      reason: 'the escape report names this and an app must be able to say it',
    );
  });
}
