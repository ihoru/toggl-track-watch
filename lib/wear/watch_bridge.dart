import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../src/models.dart';

/// The watch's native side (see android/app/src/wear/.../MainActivity.kt).
abstract class WatchBridge {
  Future<ViewState> getState();
  Stream<ViewState> get updates;

  /// Rotary crown scroll deltas in logical pixels.
  Stream<double> get rotary;

  Future<void> start(String description, int? projectId);
  Future<void> stop(String entryId);
  Future<void> update(String entryId, String description, int? projectId);
  Future<void> delete(String entryId);
  Future<void> refresh();

  /// Opens the system voice/keyboard input. Returns null when cancelled.
  Future<String?> textInput(String label);
}

class ChannelWatchBridge implements WatchBridge {
  static const _methods = MethodChannel('trackwatch/watch');
  static const _state = EventChannel('trackwatch/watch/state');
  static const _rotary = EventChannel('trackwatch/watch/rotary');

  @override
  Future<ViewState> getState() async => ViewState.decode(await _methods.invokeMethod<String>('getState') ?? '{}');

  @override
  late final Stream<ViewState> updates = _state.receiveBroadcastStream().map((e) => ViewState.decode(e as String));

  @override
  late final Stream<double> rotary = _rotary.receiveBroadcastStream().map((e) => (e as num).toDouble());

  @override
  Future<void> start(String description, int? projectId) =>
      _methods.invokeMethod('start', {'description': description, 'projectId': projectId});

  @override
  Future<void> stop(String entryId) => _methods.invokeMethod('stop', {'entryId': entryId});

  @override
  Future<void> update(String entryId, String description, int? projectId) =>
      _methods.invokeMethod('update', {'entryId': entryId, 'description': description, 'projectId': projectId});

  @override
  Future<void> delete(String entryId) => _methods.invokeMethod('delete', {'entryId': entryId});

  @override
  Future<void> refresh() => _methods.invokeMethod('refresh');

  @override
  Future<String?> textInput(String label) => _methods.invokeMethod<String>('textInput', {'label': label});
}

/// Holds the latest [ViewState] and exposes the bridge to the widget tree.
class WatchModel extends ChangeNotifier {
  WatchModel(this.bridge) {
    _sub = bridge.updates.listen(_set);
    bridge.getState().then(_set);
  }

  final WatchBridge bridge;
  late final StreamSubscription<ViewState> _sub;
  ViewState state = ViewState.empty;
  bool loaded = false;

  void _set(ViewState s) {
    state = s;
    loaded = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

class WatchScope extends InheritedNotifier<WatchModel> {
  const WatchScope({super.key, required WatchModel model, required super.child}) : super(notifier: model);

  static WatchModel of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<WatchScope>()!.notifier!;

  /// Access without subscribing to changes (for callbacks).
  static WatchModel read(BuildContext context) => context.getInheritedWidgetOfExactType<WatchScope>()!.notifier!;
}
