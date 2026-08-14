import 'package:flutter/foundation.dart' as flutter;
import 'package:zenrouter_core/zenrouter_core.dart';

/// Adapts a Flutter foundation [flutter.Listenable] (`ValueNotifier`,
/// `ChangeNotifier`, etc.) to [ListenableMixin] for
/// [RouteGuard.canPopListenable].
///
/// Prefer [ListenableToListenableMixin.toListenableMixin]:
///
/// ```dart
/// final dirty = ValueNotifier(false);
///
/// @override
/// ListenableMixin? get canPopListenable => dirty.toListenableMixin();
/// ```
class FlutterListenableMixin implements ListenableMixin {
  /// Creates an adapter around a Flutter [flutter.Listenable].
  FlutterListenableMixin(this._listenable);

  final flutter.Listenable _listenable;

  @override
  void addListener(void Function() listener) =>
      _listenable.addListener(listener);

  @override
  void removeListener(void Function() listener) =>
      _listenable.removeListener(listener);
}

/// One adapter per listenable, so wrapping the same object twice hands back the
/// same wrapper.
///
/// These conversions sit inside getters that are read on every build —
/// `canPopListenable` is the common one — and a fresh wrapper each time is a
/// different object to `ListenableBuilder`, which then drops its listener and
/// re-registers it on every frame. An `Expando` keeps each wrapper for exactly
/// as long as the thing it wraps.
final _mixinAdapters = Expando<ListenableMixin>('zenrouter.listenableMixin');
final _flutterAdapters = Expando<flutter.Listenable>('zenrouter.listenable');

/// Converts a Flutter [flutter.Listenable] to [ListenableMixin].
extension ListenableToListenableMixin on flutter.Listenable {
  /// Wraps this listenable as a [ListenableMixin] for
  /// [RouteGuard.canPopListenable].
  ListenableMixin toListenableMixin() =>
      _mixinAdapters[this] ??= FlutterListenableMixin(this);
}

/// Adapts a [ListenableMixin] to Flutter's [flutter.Listenable] for use with
/// [ListenableBuilder] / [AnimatedBuilder].
class ListenableMixinToFlutter extends flutter.Listenable {
  /// Creates an adapter around a [ListenableMixin].
  ListenableMixinToFlutter(this._listenable);

  final ListenableMixin _listenable;

  @override
  void addListener(flutter.VoidCallback listener) =>
      _listenable.addListener(listener);

  @override
  void removeListener(flutter.VoidCallback listener) =>
      _listenable.removeListener(listener);
}

/// Converts a [ListenableMixin] to Flutter's [flutter.Listenable].
extension ListenableMixinToFlutterListenable on ListenableMixin {
  /// Wraps this mixin as a Flutter [flutter.Listenable] for
  /// [ListenableBuilder] / [AnimatedBuilder].
  flutter.Listenable toFlutterListenable() =>
      _flutterAdapters[this] ??= ListenableMixinToFlutter(this);
}
