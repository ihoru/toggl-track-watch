import 'dart:async';

import 'package:trackwatch/phone/phone_bridge.dart';
import 'package:trackwatch/src/models.dart';
import 'package:trackwatch/wear/watch_bridge.dart';

final now = DateTime.now();

ViewState sampleState({bool running = true}) => ViewState(
  configured: true,
  projects: const [
    Project(id: 1, name: 'Client A', color: '#0b83d9'),
    Project(id: 2, name: 'Internal', color: '#e36a00'),
  ],
  favorites: const [
    Favorite(description: 'Deep work', projectId: 1),
    Favorite(description: 'Email', projectId: null),
  ],
  frequent: const [
    Frequent(description: 'Coding', projectId: 1, count: 12),
    Frequent(description: 'Standup', projectId: 2, count: 5),
  ],
  entries: [
    if (running)
      TimeEntry(
        id: '10',
        description: 'Coding',
        projectId: 1,
        start: now.subtract(const Duration(minutes: 5)),
        stop: null,
      ),
    TimeEntry(
      id: '9',
      description: 'Standup',
      projectId: 2,
      start: now.subtract(const Duration(hours: 2)),
      stop: now.subtract(const Duration(hours: 1, minutes: 45)),
      pending: true,
    ),
    TimeEntry(
      id: '8',
      description: 'Coding',
      projectId: 1,
      start: now.subtract(const Duration(days: 1, hours: 3)),
      stop: now.subtract(const Duration(days: 1, hours: 1)),
    ),
  ],
  lastSync: now,
  quotaRemaining: 27,
  quotaResetsAt: now.add(const Duration(minutes: 30)),
);

class FakeWatchBridge implements WatchBridge {
  FakeWatchBridge(this.state);

  ViewState state;
  final calls = <String>[];
  final _updates = StreamController<ViewState>.broadcast();
  String? nextText;

  void emit(ViewState s) {
    state = s;
    _updates.add(s);
  }

  @override
  Future<ViewState> getState() async => state;

  @override
  Stream<ViewState> get updates => _updates.stream;

  @override
  Stream<double> get rotary => const Stream.empty();

  @override
  Future<void> start(String description, int? projectId) async => calls.add('start:$description:$projectId');

  @override
  Future<void> stop(String entryId) async => calls.add('stop:$entryId');

  @override
  Future<void> update(String entryId, String description, int? projectId) async =>
      calls.add('update:$entryId:$description:$projectId');

  @override
  Future<void> delete(String entryId) async => calls.add('delete:$entryId');

  @override
  Future<void> refresh() async => calls.add('refresh');

  @override
  Future<String?> textInput(String label) async => nextText;

  final _ambient = StreamController<String>.broadcast();
  Map<String, dynamic> uiState = {};
  bool phoneReachable = true;

  void setAmbient(String event) => _ambient.add(event);

  @override
  Stream<String> get ambient => _ambient.stream;

  @override
  Future<bool> openOnPhone() async {
    calls.add('openOnPhone');
    return phoneReachable;
  }

  @override
  Future<Map<String, dynamic>> loadUiState() async => {...uiState};

  @override
  Future<String> appVersion() async => '1.1.0 (2)';

  @override
  Future<void> saveUiState(Map<String, dynamic> state) async => uiState = {...state};
}

class FakePhoneBridge implements PhoneBridge {
  FakePhoneBridge(this.snapshot);

  PhoneSnapshot snapshot;
  List<Favorite>? savedFavorites;
  String? token;
  final _updates = StreamController<PhoneSnapshot>.broadcast();

  @override
  Future<PhoneSnapshot> getState() async => snapshot;

  @override
  Stream<PhoneSnapshot> get updates => _updates.stream;

  @override
  Future<PhoneSnapshot> setToken(String token) async {
    this.token = token;
    snapshot = PhoneSnapshot(sampleState(), const Account(name: 'Ihor', email: 'e@x', workspace: 'WS'));
    return snapshot;
  }

  @override
  Future<void> signOut() async {}

  /// What the fake Google backup returns; null means no backup.
  PhoneSnapshot? backup;
  int restoreCalls = 0;

  @override
  Future<PhoneSnapshot?> restoreFromCloud() async {
    restoreCalls++;
    if (backup != null) snapshot = backup!;
    return backup;
  }

  @override
  Future<void> setFavorites(List<Favorite> favorites) async => savedFavorites = favorites;

  @override
  Future<void> syncNow() async {}

  @override
  Future<bool> watchConnected() async => true;

  final started = <Favorite>[];
  StartResult startResult = StartResult.api;
  bool compact = false;

  @override
  Future<StartResult> startTimer(Favorite favorite) async {
    started.add(favorite);
    return startResult;
  }

  @override
  Future<bool> getCompact() async => compact;

  @override
  Future<String> appVersion() async => '1.1.0 (2)';

  @override
  Future<void> setCompact(bool compact) async => this.compact = compact;
}
