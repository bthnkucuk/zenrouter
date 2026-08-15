/// **This file tests the framework, not this package, and covers no line of it.**
///
/// It imports nothing from `package:shits`. Every widget under test here is
/// built by this file — its own `PrimaryScrollController`, its own spy
/// controller, its own `ListView` — so no change to `lib/src/scroll/` can make
/// any row in it fail, and no row in it is evidence that anything in this
/// package works. What it establishes is the *premise* the package is built on:
/// that `automaticallyInheritForPlatforms: TargetPlatform.values.toSet()` is
/// what makes a bare list inherit on a desktop, and that the framework's own
/// default silently does not.
///
/// The coverage of our own wiring — `PanelScrollAttachment` publishing that
/// controller, on every platform, with a real gesture reaching the panel — is
/// `attachment_test.dart`. Cite that one for the desktop claim; citing this one
/// is how the claim went untested while looking covered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ============================================================================
// Written before the arbiter exists, because the arbiter rests on this: a panel
// captures its content's scrolling by putting its own controller in the ambient
// `PrimaryScrollController`, and a plain `ListView` picks it up with nothing
// asked of the app.
//
// The framework does not give that away for free. `PrimaryScrollController`
// inherits only on `automaticallyInheritForPlatforms`, which defaults to the
// touch platforms — so on macOS, Windows and Linux a bare list silently does not
// inherit, and a sheet that relied on the default would ignore its own content
// on every desktop. `smooth_sheets` ships that hole.
//
// So the panel must pass every platform, and this file is what says why, in a
// form that fails if someone removes the argument as redundant.
// ============================================================================

/// Records what attached, so "did the panel capture this list" is a fact rather
/// than an inference from behaviour.
class SpyController extends ScrollController {
  final attached = <ScrollPosition>[];

  @override
  void attach(ScrollPosition position) {
    attached.add(position);
    super.attach(position);
  }
}

/// What the panel will install: a controller that inherits everywhere.
Widget everywhere({
  required ScrollController controller,
  required Widget child,
}) => PrimaryScrollController(
  controller: controller,
  automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
  child: child,
);

Future<bool> captured(
  WidgetTester tester,
  Widget content, {
  required TargetPlatform platform,
  bool everyPlatform = true,
  Axis axis = Axis.vertical,
}) async {
  final spy = SpyController();
  final scope = everyPlatform
      ? PrimaryScrollController(
          controller: spy,
          automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
          scrollDirection: axis,
          child: Scaffold(body: content),
        )
      : PrimaryScrollController(
          controller: spy,
          scrollDirection: axis,
          child: Scaffold(body: content),
        );

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: scope,
    ),
  );
  await tester.pumpAndSettle();
  final result = spy.attached.isNotEmpty;
  spy.dispose();
  return result;
}

Widget get _list =>
    ListView(children: [for (var i = 0; i < 40; i++) Text('$i')]);

const _desktop = [
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
];

void main() {
  group('the panel captures its content on every platform', () {
    for (final platform in TargetPlatform.values) {
      group('$platform', () {
        testWidgets('a bare ListView', (tester) async {
          expect(
            await captured(tester, _list, platform: platform),
            isTrue,
            reason:
                'the whole no-opt-in claim: nothing panel-aware in the content, '
                'and the panel still owns its scrolling',
          );
        });

        testWidgets('a builder ListView', (tester) async {
          expect(
            await captured(
              tester,
              ListView.builder(
                itemCount: 40,
                itemBuilder: (_, i) => Text('$i'),
              ),
              platform: platform,
            ),
            isTrue,
          );
        });

        testWidgets('a CustomScrollView', (tester) async {
          expect(
            await captured(
              tester,
              CustomScrollView(
                slivers: [
                  SliverList.list(
                    children: [for (var i = 0; i < 40; i++) Text('$i')],
                  ),
                ],
              ),
              platform: platform,
            ),
            isTrue,
          );
        });
      });
    }
  });

  group('and the argument that makes it so is load-bearing', () {
    for (final platform in _desktop) {
      testWidgets('$platform does not inherit on the framework default', (
        tester,
      ) async {
        // Not a wish — a measurement. This is what a panel built on the default
        // would do on a desktop: silently ignore its own list. The test exists
        // so that removing `automaticallyInheritForPlatforms` as redundant
        // fails here instead of shipping.
        expect(
          await captured(
            tester,
            _list,
            platform: platform,
            everyPlatform: false,
          ),
          isFalse,
        );
      });
    }

    testWidgets('while a touch platform would have hidden it', (tester) async {
      expect(
        await captured(
          tester,
          _list,
          platform: TargetPlatform.iOS,
          everyPlatform: false,
        ),
        isTrue,
        reason:
            'which is why the hole is invisible until someone runs a desktop',
      );
    });
  });

  group('what must not be captured', () {
    testWidgets('a list that brought its own controller', (tester) async {
      // Not a defect: it is the case the arbiter has to notice and complain
      // about loudly, rather than ignore.
      final own = ScrollController();
      addTearDown(own.dispose);
      expect(
        await captured(
          tester,
          ListView(
            controller: own,
            children: [for (var i = 0; i < 40; i++) Text('$i')],
          ),
          platform: TargetPlatform.iOS,
        ),
        isFalse,
      );
    });

    testWidgets('one that opted out with primary: false', (tester) async {
      expect(
        await captured(
          tester,
          ListView(
            primary: false,
            children: [for (var i = 0; i < 40; i++) Text('$i')],
          ),
          platform: TargetPlatform.iOS,
        ),
        isFalse,
      );
    });

    testWidgets('a horizontal list under a vertical panel', (tester) async {
      // A carousel inside a sheet scrolls itself. The axis check is the
      // framework's, and it is exactly the behaviour we want, so it is pinned
      // rather than left to chance.
      expect(
        await captured(
          tester,
          ListView(
            scrollDirection: Axis.horizontal,
            children: [for (var i = 0; i < 40; i++) Text('$i')],
          ),
          platform: TargetPlatform.iOS,
        ),
        isFalse,
      );
    });

    testWidgets('the inner list of a nested pair', (tester) async {
      // The framework inserts `PrimaryScrollController.none` around a scroll
      // view's children, so only the outer list reaches the panel. Free, and
      // worth pinning: it is the difference between a tab of lists working and
      // all of them fighting the panel at once.
      final spy = SpyController();
      await tester.pumpWidget(
        MaterialApp(
          home: everywhere(
            controller: spy,
            child: Scaffold(
              body: ListView(
                children: [
                  SizedBox(
                    height: 200,
                    child: ListView(
                      children: [for (var i = 0; i < 20; i++) Text('inner $i')],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(spy.attached, hasLength(1), reason: 'the outer list, and only it');
      spy.dispose();
    });
  });
}
