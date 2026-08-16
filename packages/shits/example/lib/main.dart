import 'package:flutter/material.dart';
import 'package:shits/shits.dart';

// ============================================================================
// The first example: a places panel over a map, with no router involved.
//
// This is the package's non-modal mode — the panel is a widget in the tree, the
// thing behind it stays interactive, and nothing is pushed onto a `Navigator`.
// Routes and pages are the next slice; none of what is below needs them.
//
// It exercises the four claims that are worth seeing rather than reading:
//
//   1. a bare `ListView.builder` hands scrolling off to the panel with no
//      controller, no wrapper and no configuration object;
//   2. the list's viewport is the panel's *visible* extent, so a lazy list
//      builds what is on screen and not the whole sheet;
//   3. the panel publishes its position continuously, not just its resting
//      detent — the map dims and the bar appears against a live number;
//   4. a bottom bar is pinned to the panel's edge rather than to its content.
// ============================================================================

void main() => runApp(const PlacesApp());

class PlacesApp extends StatelessWidget {
  const PlacesApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'shits — places',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const PlacesScreen(),
  );
}

class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  /// Held by the app so the buttons on the "map" can move the panel, and so the
  /// background can read where it is. A panel makes its own if none is given.
  final controller = PanelController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// The three heights, smallest first — a peek, half, and the whole safe area.
  ///
  /// `Detent.height` takes a [DetentValue] rather than an [Extent] because the
  /// two are different things: this is the content inside the panel's own safe
  /// area, and the frame adds the home indicator to it when the panel is
  /// attached to the edge. On this device the peek is a 180pt content height
  /// inside a 214pt frame.
  static const detents = DetentSet([
    Detent.height(DetentValue(100)),
    Detent.medium,
    Detent.full,
  ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Behind the panel, and still live: the buttons work at every detent,
          // because nothing here is a modal route and there is no barrier.
          _Map(controller: controller),
          Panel(
            controller: controller,
            detents: detents,
            initialDetent: Detent.medium,
            motion: PanelMotion.bouncy(),
            // Not the package's default, and here on purpose. The default,
            // `whenFullyOpen`, gives a downward drag at the largest detent to
            // the content so a `RefreshIndicator` works with nothing
            // configured — but it charges that price whether or not one is
            // there, and there is none here. With the default, the panel
            // cannot be shrunk by dragging its own list at `full`, and this
            // slice has no grabber to shrink it with either. Measured on a
            // device; the default is under review.
            refreshPolicy: PanelRefreshPolicy.never,
            child: PanelContentScaffold(
              extendBodyBehindBottomBar: true,
              bottomBarVisibility: BottomBarVisibility.conditional(
                // Re-evaluated on every metrics change, which is why the panel
                // has to publish its position and not only its detent.
                isVisible: (metrics) => metrics.openProgress > 0.5,
                identity: 'half-open',
              ),
              bottomBar: const _Bar(),
              // No controller, no wrapper, no configuration object. Dragging
              // this list grows the panel to its next detent and then scrolls,
              // in one gesture, on every platform.
              body: ColoredBox(
                color: Colors.amber,
                child: ListView.builder(
                  itemCount: 200,
                  itemBuilder: (context, i) => ListTile(
                    leading: CircleAvatar(child: Text('${i + 1}')),
                    title: Text('Place ${i + 1}'),
                    subtitle: Text('${(i * 37) % 900 + 100} m away'),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stands in for a map. Dims as the panel opens, so the panel's position is
/// visibly a continuous quantity rather than a detent that snaps.
class _Map extends StatelessWidget {
  const _Map({required this.controller});

  final PanelController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final open = controller.value?.openProgress ?? 0;
        return ColoredBox(
          color: Color.lerp(
            const Color(0xFFE8EDE7),
            const Color(0xFF9AA79B),
            open,
          )!,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'open ${(open * 100).round()}%',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'The map keeps working at every detent — nothing here is '
                    'behind a barrier.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (label, detent) in const [
                        ('peek', Detent.height(DetentValue(180))),
                        ('half', Detent.medium),
                        ('full', Detent.full),
                      ])
                        FilledButton.tonal(
                          onPressed: () => controller.animateTo(detent),
                          child: Text(label),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pinned to the panel's edge rather than to the end of its content, so it stays
/// put while the list scrolls underneath it.
class _Bar extends StatelessWidget {
  const _Bar();

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Expanded(child: Text('200 places nearby')),
              FilledButton(
                // Reached from inside the panel's own content, with nothing
                // threaded down to get here.
                onPressed: () =>
                    PanelScope.of(context).animateTo(Detent.medium),
                child: const Text('Collapse'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
