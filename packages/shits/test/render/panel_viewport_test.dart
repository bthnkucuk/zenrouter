import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/detent.dart';
import 'package:shits/src/geometry/detent_set.dart';
import 'package:shits/src/geometry/units.dart';
import 'package:shits/src/model/activity.dart';
import 'package:shits/src/model/panel_model.dart';
import 'package:shits/src/render/panel_viewport.dart';
import 'package:shits/src/render/render_panel.dart';

import '../fixtures/devices.dart';
import 'harness.dart';

// ============================================================================
// The widget half of the layer, which exists to do exactly one thing a render
// object cannot: read inherited state.
//
// Two claims, and they pull in opposite directions, which is why both are here.
// It must read the *right* inherited values — `viewPadding` and not `padding`,
// or every detent loses 34pt the moment a keyboard opens — and it must read as
// *few* of them as it can, because `MediaQuery.of` subscribes to all of them and
// turns a text-scale change into a rebuild of the panel.
//
// The third claim is the one DESIGN.md argues from the SDK source and nobody
// has run: that `getDryLayout` answers correctly for a `ListView` where
// `getMinIntrinsicHeight` throws. That is a fact about Flutter, so it is
// asserted against Flutter, with no panel in the tree — and it is green today.
// ============================================================================

const _peek = Detent.height(DetentValue(180));
const _sheet = DetentSet([_peek, Detent.medium, Detent.full]);
const _config = PanelConfig(detents: _sheet, initialDetent: Detent.medium);

/// An iPhone 17 Pro upright, with the keyboard down.
const _portrait = MediaQueryData(
  size: Size(402, 874),
  devicePixelRatio: 3,
  viewPadding: EdgeInsets.only(top: 62, bottom: 34),
  padding: EdgeInsets.only(top: 62, bottom: 34),
);

/// The same phone with a 336pt keyboard up.
///
/// **`padding` and `viewPadding` disagree here, exactly as the engine makes them
/// disagree.** `padding` is `viewPadding` less whatever `viewInsets` has eaten,
/// so the home indicator's 34pt is gone from one and kept in the other. That is
/// the whole of KB6, and it is why this fixture sets all three by hand rather
/// than letting a default hide the difference.
const _keyboard = MediaQueryData(
  size: Size(402, 874),
  devicePixelRatio: 3,
  viewPadding: EdgeInsets.only(top: 62, bottom: 34),
  viewInsets: EdgeInsets.only(bottom: 336),
  padding: EdgeInsets.only(top: 62),
);

/// Pumps [child] as the content of a panel on a device the size of [data].
///
/// The surface is resized before the pump, and that is not cosmetic: the test
/// window is 800x600, `SizedBox` enforces the incoming constraints over its own,
/// and a panel clamped to 600 resolves `.medium` to 316.24 — a number that looks
/// like a bug in the detent arithmetic and is a bug in the fixture. Sizing the
/// view is what makes 469.68 the answer to a question about the panel rather
/// than about the harness.
Future<void> pumpPanel(
  WidgetTester tester,
  Widget child, {
  MediaQueryData data = _portrait,
}) async {
  tester.view.physicalSize = data.size * data.devicePixelRatio;
  tester.view.devicePixelRatio = data.devicePixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(data: data, child: child),
    ),
  );
}

/// Content that counts how often it is rebuilt and how often it is laid out.
class _Content extends StatelessWidget {
  const _Content({required this.box, required this.onBuild});

  final CountingBox box;
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return _Leaf(box);
  }
}

class _Leaf extends LeafRenderObjectWidget {
  const _Leaf(this.box);

  final CountingBox box;

  @override
  RenderObject createRenderObject(BuildContext context) => box;
}

void main() {
  late PanelModel model;

  setUp(
    () => model = PanelModel(config: _config, layout: kIPhone17Pro.layout()),
  );
  tearDown(() => model.dispose());

  group('the bridge reads the right insets', () {
    testWidgets('a panel at .medium is 469.68 tall', (tester) async {
      final box = CountingBox();
      await pumpPanel(
        tester,
        PanelViewport(
          model: model,
          child: _Content(box: box, onBuild: () {}),
        ),
      );

      expect(spanOf(box.lastConstraints), closeTo(mediumFrameOnPro, 1e-9));
    });

    testWidgets('and it is still 469.68 with the keyboard up', (tester) async {
      final box = CountingBox();
      await pumpPanel(
        tester,
        PanelViewport(
          model: model,
          child: _Content(box: box, onBuild: () {}),
        ),
        data: _keyboard,
      );

      expect(
        spanOf(box.lastConstraints),
        closeTo(mediumFrameOnPro, 1e-9),
        reason:
            'KB6. The keyboard changed viewInsets and nothing else this panel '
            'reads, so no detent moved',
      );
      expect(
        spanOf(box.lastConstraints),
        isNot(closeTo(0.56 * kIPhone17Pro.baseline, 0.5)),
        reason:
            'a bridge reading MediaQuery.paddingOf would land here instead: '
            'padding.bottom collapses to 0 under the keyboard, so the frame '
            'loses the 34pt the detent value sits above',
      );
    });
  });

  group('an extent change does not reach the widget tree', () {
    testWidgets('the content is built once, however far the panel moves', (
      tester,
    ) async {
      var builds = 0;
      final box = CountingBox();
      await pumpPanel(
        tester,
        PanelViewport(
          model: model,
          child: _Content(box: box, onBuild: () => builds++),
        ),
      );

      expect(builds, 1);
      box.reset();

      final drag = DragPanelActivity(from: model.extent);
      model.beginActivity(drag);
      for (var i = 0; i < 30; i++) {
        drag.update(2);
        await tester.pump();
      }

      expect(
        box.layouts,
        greaterThan(0),
        reason:
            'the panel really did move — otherwise the build count below is a '
            'fact about a frame where nothing happened',
      );
      expect(
        builds,
        1,
        reason:
            'this is the claim an app actually feels. A PanelViewport that '
            'listened to the model in a State and called setState would land '
            'here with 31, and every widget in the sheet would rebuild with it',
      );
    });
  });

  group('the render object is configured, and updated in place', () {
    testWidgets('the widget hands its policies down', (tester) async {
      await pumpPanel(
        tester,
        PanelViewport(model: model, child: const SizedBox()),
      );

      final panel = tester.renderObject<RenderPanelViewport>(
        find.byType(PanelViewport),
      );
      expect(panel.anchor.name, 'bottom');
      expect(panel.attachment.name, 'edgeAttached');
      expect(panel.sizing, PanelSizing.resize);
      expect(panel.measuresContent, isFalse);
      expect(identical(panel.model, model), isTrue);
    });

    testWidgets('including the ones it is not defaulted to', (tester) async {
      // The defaults above are also what a `createRenderObject` that dropped
      // every parameter on the floor would produce, so each is asserted again
      // at a value the constructor cannot have supplied. `measuresContent` and
      // `attachment` are the two that would otherwise be invisible: nothing
      // else in this file reads either.
      await pumpPanel(
        tester,
        PanelViewport(
          model: model,
          attachment: EdgeAttachment.floating,
          measuresContent: true,
          child: const SizedBox(),
        ),
      );

      final panel = tester.renderObject<RenderPanelViewport>(
        find.byType(PanelViewport),
      );
      expect(panel.attachment, EdgeAttachment.floating);
      expect(panel.measuresContent, isTrue);
      expect(
        panel.panelRect.height,
        closeTo(0.56 * kIPhone17Pro.baseline, 1e-9),
        reason:
            'and the attachment arrived early enough to matter: a floating '
            '.medium is 435.68, which is 469.68 less the 34pt an attached '
            'panel absorbs',
      );
    });

    testWidgets('the reading direction comes from Directionality', (
      tester,
    ) async {
      // The grep at the bottom of this file pins that the source says
      // `Directionality.of`; this pins that its answer arrives somewhere. A
      // bridge that read the string and then passed a constant would satisfy
      // the grep and fail here.
      await pumpPanel(
        tester,
        Directionality(
          textDirection: TextDirection.rtl,
          child: PanelViewport(model: model, child: const SizedBox()),
        ),
      );

      expect(model.layout.textDirection, TextDirection.rtl);
      expect(
        model.layout.devicePixelRatio,
        3,
        reason:
            'and the pixel ratio with it — the number every settle sizes its '
            'half-a-physical-pixel tolerance from',
      );
    });

    testWidgets('the widget describes itself', (tester) async {
      await pumpPanel(
        tester,
        PanelViewport(
          model: model,
          attachment: EdgeAttachment.floating,
          measuresContent: true,
          child: const SizedBox(),
        ),
      );

      final properties = DiagnosticPropertiesBuilder();
      tester
          .widget<PanelViewport>(find.byType(PanelViewport))
          .debugFillProperties(properties);
      final described = properties.properties
          .map((property) => property.toString())
          .join('\n');

      expect(
        described,
        allOf(
          contains('bottom'),
          contains('floating'),
          contains('resize'),
          contains('measures content'),
        ),
        reason:
            'the four policies are the whole of what this widget is, so an '
            'inspector that shows none of them shows a panel with no shape',
      );
    });

    testWidgets('a keyboard opening updates the same render object', (
      tester,
    ) async {
      final box = CountingBox();
      Future<void> pump(MediaQueryData data) => pumpPanel(
        tester,
        PanelViewport(
          model: model,
          child: _Content(box: box, onBuild: () {}),
        ),
        data: data,
      );

      await pump(_portrait);
      final before = tester.renderObject<RenderPanelViewport>(
        find.byType(PanelViewport),
      );
      box.reset();

      await pump(_keyboard);

      expect(
        identical(
          tester.renderObject<RenderPanelViewport>(find.byType(PanelViewport)),
          before,
        ),
        isTrue,
        reason:
            'updateRenderObject, not a rebuild of the render tree — a keyboard '
            'animation runs this on every one of its frames',
      );
      expect(
        before.media.viewInsets.bottom,
        336,
        reason: 'and the new insets arrived, which a keyboard policy will read',
      );
      expect(
        model.layout.viewInsets.bottom,
        336,
        reason:
            'all the way into the layout the model committed. Nothing reads it '
            'yet — KeyboardPolicy is not in this slice — so without this the '
            'render object could drop it on the floor and every other test '
            'would still be green',
      );
    });

    testWidgets('a rebuild that changed something carries it across', (
      tester,
    ) async {
      // The partner to "a rebuild that changed nothing lays nothing out": that
      // test proves the six setters decline, and this proves the widget
      // actually offers them. `updateRenderObject` writing four of its five
      // policies is a panel that adopts a page's new configuration except for
      // the one field the page changed, which is a bug with no symptom until
      // someone changes it.
      final box = CountingBox();
      Future<void> pump({
        required EdgeAttachment attachment,
        required bool measuresContent,
      }) => pumpPanel(
        tester,
        PanelViewport(
          model: model,
          attachment: attachment,
          measuresContent: measuresContent,
          child: _Content(box: box, onBuild: () {}),
        ),
      );

      await pump(
        attachment: EdgeAttachment.edgeAttached,
        measuresContent: false,
      );
      final before = tester.renderObject<RenderPanelViewport>(
        find.byType(PanelViewport),
      );
      expect(box.dryLayouts, 0);

      await pump(attachment: EdgeAttachment.floating, measuresContent: true);

      expect(
        identical(
          tester.renderObject<RenderPanelViewport>(find.byType(PanelViewport)),
          before,
        ),
        isTrue,
        reason: 'in place, not a new render object',
      );
      expect(before.attachment, EdgeAttachment.floating);
      expect(before.measuresContent, isTrue);
      expect(
        spanOf(box.lastConstraints),
        closeTo(0.56 * kIPhone17Pro.baseline, 1e-9),
        reason: 'and the new attachment reached the very next layout pass',
      );
      expect(
        box.dryLayouts,
        greaterThan(0),
        reason: 'as did the new measurement policy',
      );
    });

    testWidgets('a rebuild can hand the panel a different model', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        PanelViewport(model: model, child: const SizedBox()),
      );

      final replacement = PanelModel(
        config: _config,
        layout: kIPhone17Pro.layout(),
      );
      addTearDown(replacement.dispose);
      await pumpPanel(
        tester,
        PanelViewport(model: replacement, child: const SizedBox()),
      );

      expect(
        identical(
          tester
              .renderObject<RenderPanelViewport>(find.byType(PanelViewport))
              .model,
          replacement,
        ),
        isTrue,
        reason:
            'a paged host swaps the model when the page changes, and a panel '
            'still driven by the outgoing one is a panel two things are moving',
      );
    });

    testWidgets('the two refusals arrive down both paths', (tester) async {
      // A non-default anchor and a non-default sizing are both refusals in this
      // slice, so a refusal is the *only* observable either has — which makes
      // it the only thing that can show the parameter was forwarded rather than
      // quietly defaulted. Every other widget test in this file uses the
      // defaults, so without these four `createRenderObject` and
      // `updateRenderObject` could drop both fields and stay green.
      //
      // No child anywhere here: the layout that refuses never reaches one, and
      // a child left unlaid-out reports a second, derived failure in the paint
      // phase that buries the first.
      Future<Object?> pumpAndTake(Widget panel) async {
        await pumpPanel(tester, panel);
        return tester.takeException();
      }

      Matcher refuses(String name) => isA<UnimplementedError>().having(
        (error) => error.message,
        'message',
        contains(name),
      );

      // A fresh key is a fresh element, and so createRenderObject; the same key
      // again is updateRenderObject on the render object already there.
      expect(
        await pumpAndTake(
          PanelViewport(
            key: const ValueKey<String>('created'),
            model: model,
            anchor: PanelAnchor.top,
          ),
        ),
        refuses('PanelAnchor.top'),
      );
      expect(
        await pumpAndTake(
          PanelViewport(
            key: const ValueKey<String>('created'),
            model: model,
            sizing: PanelSizing.translate,
          ),
        ),
        refuses('PanelSizing.translate'),
      );
      expect(
        await pumpAndTake(
          PanelViewport(
            key: const ValueKey<String>('recreated'),
            model: model,
            sizing: PanelSizing.translate,
          ),
        ),
        refuses('PanelSizing.translate'),
      );
      expect(
        await pumpAndTake(
          PanelViewport(
            key: const ValueKey<String>('recreated'),
            model: model,
            anchor: PanelAnchor.top,
          ),
        ),
        refuses('PanelAnchor.top'),
      );
    });

    testWidgets('a rebuild that changed nothing lays nothing out', (
      tester,
    ) async {
      final box = CountingBox();
      Widget panel() => PanelViewport(
        model: model,
        child: _Content(box: box, onBuild: () {}),
      );

      await pumpPanel(tester, panel());
      box.reset();
      // Identity, not equality. `applyLayout` writes the layout it was handed
      // on every pass, and two passes produce two `PanelLayout` instances that
      // compare equal — so `==` cannot tell "the panel laid out again and got
      // the same answer" from "the panel did not lay out". Counting the child's
      // layouts cannot either: `RenderObject.layout` returns early when the
      // constraints are unchanged, so a wasted *panel* layout costs the child
      // nothing and is invisible from down there.
      final committed = model.layout;

      // A fresh widget instance carrying identical values, which is what every
      // rebuild of an ancestor produces. `updateRenderObject` runs; each setter
      // compares and declines.
      await pumpPanel(tester, panel());

      expect(
        identical(model.layout, committed),
        isTrue,
        reason:
            'the discriminating form of "an idle panel is free". Drop the == '
            'guard from any one of the six setters and the panel lays out again '
            'on every rebuild of anything above it, for the life of the app',
      );
      expect(box.layouts, 0);
    });
  });

  group('content measurement, against a real lazy viewport', () {
    testWidgets('a ListView answers a dry layout with the span it was offered', (
      tester,
    ) async {
      // No panel in this tree. This is DESIGN.md's own premise — `viewport.dart`
      // is `sizedByParent => true` with `computeDryLayout => constraints.biggest`
      // — asserted against Flutter rather than cited from it, so that a version
      // bump that moved it fails here rather than inside the panel.
      await pumpPanel(
        tester,
        ListView(
          children: [for (var i = 0; i < 200; i++) const SizedBox(height: 40)],
        ),
      );

      final viewport = tester.renderObject<RenderBox>(find.byType(Viewport));

      expect(
        viewport.getDryLayout(
          const BoxConstraints(maxWidth: 402, maxHeight: 812),
        ),
        const Size(402, 812),
      );
      expect(
        () => viewport.getMinIntrinsicHeight(402),
        throwsA(isA<FlutterError>()),
        reason:
            'and the other route is not merely worse, it is unavailable. '
            'stupid_simple_sheet suppresses this assert in a method it named '
            '_illegallyComputeMinIntrinsicHeight and gets 0.0 back',
      );
    });

    testWidgets('and the panel measures its content the same way', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        PanelViewport(
          model: model,
          measuresContent: true,
          child: ListView(
            children: [
              for (var i = 0; i < 200; i++) const SizedBox(height: 40),
            ],
          ),
        ),
      );

      final panel = tester.renderObject<RenderPanelViewport>(
        find.byType(PanelViewport),
      );

      expect(
        panel.measureContent(kIPhone17Pro.panelBaseline()).px,
        closeTo(fullFrameOnPro, 1e-9),
        reason:
            'a list longer than the panel reports the panel ceiling, which is '
            'the only answer a lazy viewport can give and the right one for a '
            'detent that clamps to the baseline',
      );
    });
  });

  test('the bridge reads aspects, not the whole MediaQuery', () {
    // A grep, and labelled as one. The behaviour it stands in for — which
    // elements rebuild when an unread aspect changes — is A7's instrument and
    // is not measurable from here; what is checkable now is that nobody
    // "simplified" four aspect reads into one `MediaQuery.of`, which is the
    // edit that would silently undo it.
    final file = File('lib/src/render/panel_viewport.dart');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run from the package root, not the workspace root',
    );
    final code = [
      for (final line in file.readAsLinesSync())
        if (!line.trimLeft().startsWith('//')) line,
    ].join('\n');

    expect(code, contains('MediaQuery.viewPaddingOf'));
    expect(code, contains('MediaQuery.viewInsetsOf'));
    expect(code, contains('MediaQuery.devicePixelRatioOf'));
    expect(code, contains('Directionality.of'));
    expect(
      code,
      isNot(contains('MediaQuery.of(')),
      reason:
          'subscribes to every field, including the ones a panel never reads',
    );
    expect(
      code,
      isNot(contains('MediaQuery.paddingOf')),
      reason:
          'padding collapses under the keyboard; viewPadding is the one that '
          'keeps its 34pt — KB6, and PanelBaseline cannot refuse the wrong one '
          'because both are EdgeInsets',
    );
    expect(
      code,
      isNot(contains('MediaQuery.sizeOf')),
      reason:
          'the viewport is the panel own constraints, not the window. A panel '
          'in a split view is smaller than the screen and its .full detent '
          'would hang off the bottom of its own box',
    );
  });
}
