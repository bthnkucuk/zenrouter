import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';
import 'package:shits/src/geometry/anchor.dart';
import 'package:shits/src/geometry/baseline.dart';
import 'package:shits/src/geometry/layout.dart';
import 'package:shits/src/geometry/units.dart';

/// One measured device: the numbers iOS was observed to use, not numbers this
/// package computes.
///
/// [baseline] is the observed `maxDetentValue`. It is stored rather than derived
/// so that a test asserting `PanelBaseline.from` reproduces it is comparing
/// against a measurement, not against the same arithmetic run twice.
@immutable
class DeviceFixture {
  /// Records one row of the measured table.
  const DeviceFixture({
    required this.name,
    required this.size,
    required this.viewPadding,
    required this.baseline,
    required this.devicePixelRatio,
  });

  /// The device, for a test name.
  final String name;

  /// Logical size of the viewport, portrait.
  final Size size;

  /// `MediaQueryData.viewPadding`. Never `padding`: this is the inset that keeps
  /// its 34pt with the keyboard up.
  final EdgeInsets viewPadding;

  /// The measured iOS `maxDetentValue` for this device.
  final double baseline;

  /// Physical pixels per logical pixel. Every row here is a 3x display, which is
  /// why the platform reports 0.56 x 778 as 435.667 rather than 435.68.
  final double devicePixelRatio;

  /// The baseline this device produces for [anchor].
  PanelBaseline panelBaseline({
    PanelAnchor anchor = PanelAnchor.bottom,
    EdgeAttachment attachment = EdgeAttachment.edgeAttached,
    TextDirection textDirection = TextDirection.ltr,
  }) => PanelBaseline.from(
    viewport: size,
    viewPadding: viewPadding,
    anchor: anchor,
    textDirection: textDirection,
    attachment: attachment,
  );

  /// A whole layout pass on this device.
  ///
  /// [viewInsets] defaults to zero and is the only way to simulate a keyboard;
  /// nothing it is passed can reach a detent, which is what
  /// `baseline_test.dart` proves.
  PanelLayout layout({
    EdgeInsets viewInsets = EdgeInsets.zero,
    Extent? contentExtent,
    PanelAnchor anchor = PanelAnchor.bottom,
    EdgeAttachment attachment = EdgeAttachment.edgeAttached,
    TextDirection textDirection = TextDirection.ltr,
  }) => PanelLayout(
    baseline: panelBaseline(
      anchor: anchor,
      attachment: attachment,
      textDirection: textDirection,
    ),
    viewInsets: viewInsets,
    contentExtent: contentExtent,
    devicePixelRatio: devicePixelRatio,
    textDirection: textDirection,
  );

  @override
  String toString() => name;
}

/// iPhone 17 Pro. The device every worked example in DESIGN.md is quoted on.
const DeviceFixture kIPhone17Pro = DeviceFixture(
  name: 'iPhone 17 Pro',
  size: Size(402, 874),
  viewPadding: EdgeInsets.only(top: 62, bottom: 34),
  baseline: 778.0,
  devicePixelRatio: 3.0,
);

/// iPhone 17 Pro Max — the same safe-area geometry, a taller screen.
const DeviceFixture kIPhone17ProMax = DeviceFixture(
  name: 'iPhone 17 Pro Max',
  size: Size(440, 956),
  viewPadding: EdgeInsets.only(top: 62, bottom: 34),
  baseline: 860.0,
  devicePixelRatio: 3.0,
);

/// iPhone 17 — the second safe-area geometry, with a 47pt top inset.
const DeviceFixture kIPhone17 = DeviceFixture(
  name: 'iPhone 17',
  size: Size(393, 844),
  viewPadding: EdgeInsets.only(top: 47, bottom: 34),
  baseline: 763.0,
  devicePixelRatio: 3.0,
);

/// Every measured row.
///
/// The research prose says four devices across two safe-area geometries; three
/// rows were handed over, and they do cover both geometries (62/34 twice, 47/34
/// once). No fourth row is invented here — a made-up device would make a
/// measurement table into an arithmetic table.
const List<DeviceFixture> kMeasuredDevices = <DeviceFixture>[
  kIPhone17Pro,
  kIPhone17ProMax,
  kIPhone17,
];
