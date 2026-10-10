import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../src/models.dart';

/// The watch's native side (see android/app/src/wear/.../MainActivity.kt).
abstract class WatchBridge {
  Future<ViewState> getState();
  Stream<ViewState> get updates;

  /// Rotary crown scroll deltas in logical pixels.
  Stream<double> get rotary;

  /// Ambient mode events: "enter", "exit" and "update" (about once a minute while ambient).
  Stream<String> get ambient;

  Future<void> start(String description, int? projectId);
  Future<void> stop(String entryId);
  Future<void> update(String entryId, String description, int? projectId);
  Future<void> delete(String entryId);

  /// Moves the entry's start time (never later than now).
  Future<void> setStart(String entryId, DateTime start);

  /// Moves a stopped entry's end time (never earlier than its start or later than now).
  Future<void> setStop(String entryId, DateTime stop);
  Future<void> refresh();

  /// Opens the phone app. Returns false when the phone can't be reached.
  Future<bool> openOnPhone();

  /// Opens a web or Play Store link on the phone. Returns false when the phone can't be reached.
  Future<bool> openUrlOnPhone(String url);

  /// Watch settings (see WatchSettings.kt): "ongoing" (bool), "crownStep" (int), "haptics" (bool).
  Future<Map<String, dynamic>> getSettings();
  Future<void> setSetting(String key, Object value);

  /// Opens the system voice/keyboard input. Returns null when cancelled.
  Future<String?> textInput(String label);

  /// Last page and scroll positions, kept across app launches.
  Future<Map<String, dynamic>> loadUiState();

  /// Installed app version, e.g. "1.1.0 (2)".
  Future<String> appVersion();
  Future<void> saveUiState(Map<String, dynamic> state);
}

class ChannelWatchBridge implements WatchBridge {
  static const _methods = MethodChannel('trackwatch/watch');
  static const _state = EventChannel('trackwatch/watch/state');
  static const _rotary = EventChannel('trackwatch/watch/rotary');
  static const _ambient = EventChannel('trackwatch/watch/ambient');

  @override
  Future<ViewState> getState() async => ViewState.decode(await _methods.invokeMethod<String>('getState') ?? '{}');

  @override
  late final Stream<ViewState> updates = _state.receiveBroadcastStream().map((e) => ViewState.decode(e as String));

  @override
  late final Stream<double> rotary = _rotary.receiveBroadcastStream().map((e) => (e as num).toDouble());

  @override
  late final Stream<String> ambient = _ambient.receiveBroadcastStream().map((e) => e as String);

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
  Future<void> setStart(String entryId, DateTime start) =>
      _methods.invokeMethod('setStart', {'entryId': entryId, 'start': start.millisecondsSinceEpoch});

  @override
  Future<void> setStop(String entryId, DateTime stop) =>
      _methods.invokeMethod('setStop', {'entryId': entryId, 'stop': stop.millisecondsSinceEpoch});

  @override
  Future<void> refresh() => _methods.invokeMethod('refresh');

  @override
  Future<bool> openOnPhone() async => await _methods.invokeMethod<bool>('openOnPhone') ?? false;

  @override
  Future<bool> openUrlOnPhone(String url) async =>
      await _methods.invokeMethod<bool>('openUrlOnPhone', {'url': url}) ?? false;

  @override
  Future<Map<String, dynamic>> getSettings() async =>
      (await _methods.invokeMapMethod<String, dynamic>('getSettings')) ?? {};

  @override
  Future<void> setSetting(String key, Object value) =>
      _methods.invokeMethod('setSetting', {'key': key, 'value': value});

  @override
  Future<String?> textInput(String label) => _methods.invokeMethod<String>('textInput', {'label': label});

  @override
  Future<String> appVersion() async => await _methods.invokeMethod<String>('appVersion') ?? '';

  @override
  Future<Map<String, dynamic>> loadUiState() async {
    final json = await _methods.invokeMethod<String>('getUiState') ?? '{}';
    return (jsonDecode(json) as Map).cast<String, dynamic>();
  }

  @override
  Future<void> saveUiState(Map<String, dynamic> state) =>
      _methods.invokeMethod('setUiState', {'state': jsonEncode(state)});
}

/// Holds the latest [ViewState], ambient mode and saved UI positions, and exposes the bridge to the widget tree.
class WatchModel extends ChangeNotifier {
  WatchModel(this.bridge) {
    _subs = [bridge.updates.listen(_set), bridge.ambient.listen(_onAmbient)];
    bridge.getState().then(_set);
    bridge.appVersion().then((v) {
      version = v;
      notifyListeners();
    });
    Future.wait([bridge.loadUiState(), bridge.getSettings()]).then((loaded) {
      _ui = loaded[0];
      settings = {...settings, ...loaded[1]};
      _uiLoaded = true;
      notifyListeners();
    });
  }

  final WatchBridge bridge;
  late final List<StreamSubscription<Object>> _subs;
  ViewState state = ViewState.empty;
  bool _stateLoaded = false;
  bool _uiLoaded = false;
  Map<String, dynamic> _ui = {};
  Timer? _saveTimer;

  /// Watch settings, edited on the Settings screen.
  Map<String, dynamic> settings = {'ongoing': true, 'crownStep': 1, 'haptics': true};

  bool get showOngoing => settings['ongoing'] != false;
  bool get haptics => settings['haptics'] != false;
  int get crownStep => (settings['crownStep'] as num?)?.toInt() ?? 1;

  void setSetting(String key, Object value) {
    settings = {...settings, key: value};
    notifyListeners();
    bridge.setSetting(key, value);
  }

  /// A vibration for actions, unless turned off in Settings.
  void haptic({bool light = false}) {
    if (!haptics) return;
    light ? HapticFeedback.selectionClick() : HapticFeedback.heavyImpact();
  }

  /// Installed app version, shown on the Sync page.
  String version = '';

  /// True while the watch shows the dimmed, low-power version of the app.
  bool ambient = false;

  /// Incremented whenever a timer is started, so the pager can jump to the current timer.
  final startSignal = ValueNotifier<int>(0);

  bool get loaded => _stateLoaded && _uiLoaded;

  int get savedPage => (_ui['page'] as num?)?.toInt() ?? 0;

  double savedOffset(String key) => (_ui['offset:$key'] as num?)?.toDouble() ?? 0;

  void savePage(int page) => _save('page', page);

  void saveOffset(String key, double offset) => _save('offset:$key', offset);

  void _save(String key, Object value) {
    if (_ui[key] == value) return;
    _ui = {..._ui, key: value};
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () => bridge.saveUiState(_ui));
  }

  /// Starts a timer from anywhere in the app and shows the current-timer page.
  Future<void> start(String description, int? projectId) async {
    haptic();
    startSignal.value++;
    await bridge.start(description, projectId);
  }

  void _set(ViewState s) {
    state = s;
    _stateLoaded = true;
    notifyListeners();
  }

  void _onAmbient(String event) {
    ambient = event != 'exit';
    notifyListeners();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _saveTimer?.cancel();
    if (_ui.isNotEmpty) bridge.saveUiState(_ui);
    startSignal.dispose();
    super.dispose();
  }
}

class WatchScope extends InheritedNotifier<WatchModel> {
  const WatchScope({super.key, required WatchModel model, required super.child}) : super(notifier: model);

  static WatchModel of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<WatchScope>()!.notifier!;

  /// Access without subscribing to changes (for callbacks).
  static WatchModel read(BuildContext context) => context.getInheritedWidgetOfExactType<WatchScope>()!.notifier!;
}
