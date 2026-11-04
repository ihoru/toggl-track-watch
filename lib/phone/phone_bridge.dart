import 'dart:convert';

import 'package:flutter/services.dart';

import '../src/models.dart';

class Account {
  const Account({required this.name, required this.email, required this.workspace});

  final String name;
  final String email;
  final String workspace;
}

/// Live updates: Toggl changes pushed through a server (see server/README.md). The phone sets up
/// the Toggl webhook itself, so turning them on needs no more than a switch.
class PushStatus {
  const PushStatus({
    this.available = false,
    this.enabled = false,
    this.url = '',
    this.defaultUrl = '',
    this.active = false,
    this.error,
    this.lastMessageAt,
  });

  /// Whether this build has a Firebase configuration; without it the section is hidden.
  final bool available;

  /// The user turned live updates on.
  final bool enabled;

  /// The server in use: the one the user entered, or else [defaultUrl].
  final String url;

  /// The server built into the app; empty in builds without one.
  final String defaultUrl;

  /// The server registered the phone and Toggl validated the webhook; the phone then polls Toggl
  /// only once a day.
  final bool active;
  final String? error;
  final DateTime? lastMessageAt;

  static const unavailable = PushStatus();

  factory PushStatus.fromJson(Map<String, dynamic> json) => PushStatus(
    available: json['available'] as bool? ?? false,
    enabled: json['enabled'] as bool? ?? false,
    url: json['url'] as String? ?? '',
    defaultUrl: json['defaultUrl'] as String? ?? '',
    active: json['active'] as bool? ?? false,
    error: json['error'] as String?,
    lastMessageAt: switch (json['lastMessageAt']) {
      final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
      _ => null,
    },
  );
}

class PhoneSnapshot {
  const PhoneSnapshot(this.state, this.account, {this.push = PushStatus.unavailable});

  final ViewState state;
  final Account? account;
  final PushStatus push;

  PhoneSnapshot withState(ViewState state) => PhoneSnapshot(state, account, push: push);

  static const empty = PhoneSnapshot(ViewState.empty, null);

  factory PhoneSnapshot.decode(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    final account = json['account'] as Map<String, dynamic>?;
    final push = json['push'] as Map<String, dynamic>?;
    return PhoneSnapshot(
      ViewState.fromJson(json['state'] as Map<String, dynamic>),
      account == null
          ? null
          : Account(
              name: account['name'] as String? ?? '',
              email: account['email'] as String? ?? '',
              workspace: account['workspace'] as String? ?? '',
            ),
      push: push == null ? PushStatus.unavailable : PushStatus.fromJson(push),
    );
  }
}

/// The phone's native side (see android/app/src/phone/.../MainActivity.kt).
abstract class PhoneBridge {
  Future<PhoneSnapshot> getState();
  Stream<PhoneSnapshot> get updates;

  /// Validates the token with Toggl and stores it. Throws [PlatformException] with a readable message.
  Future<PhoneSnapshot> setToken(String token);
  Future<void> signOut();

  /// After a reinstall, restores token, favorites and settings from the Google backup.
  /// Returns null when there is no backup.
  Future<PhoneSnapshot?> restoreFromCloud();
  Future<void> setFavorites(List<Favorite> favorites);
  Future<void> syncNow();
  Future<bool> watchConnected();

  /// Turns live updates on or off. A blank [url] means the server built into the app.
  Future<PhoneSnapshot> setPush({required bool enabled, String url = ''});

  /// Installed app version, e.g. "1.1.0 (2)".
  Future<String> appVersion();

  /// Opens [url] in the browser.
  Future<void> openUrl(String url);

  /// Starts [favorite] in the official Toggl app via its start link, or through Track Watch's own
  /// Toggl connection when no app handles the link. Returns [StartResult.togglApp] or [StartResult.api].
  Future<StartResult> startTimer(Favorite favorite);

  Future<bool> getCompact();
  Future<void> setCompact(bool compact);
}

enum StartResult { togglApp, api }

class ChannelPhoneBridge implements PhoneBridge {
  static const _methods = MethodChannel('trackwatch/phone');
  static const _events = EventChannel('trackwatch/phone/state');

  @override
  Future<PhoneSnapshot> getState() async =>
      PhoneSnapshot.decode(await _methods.invokeMethod<String>('getState') ?? '{}');

  @override
  late final Stream<PhoneSnapshot> updates = _events.receiveBroadcastStream().map(
    (e) => PhoneSnapshot.decode(e as String),
  );

  @override
  Future<PhoneSnapshot> setToken(String token) async =>
      PhoneSnapshot.decode((await _methods.invokeMethod<String>('setToken', {'token': token}))!);

  @override
  Future<void> signOut() => _methods.invokeMethod('signOut');

  @override
  Future<PhoneSnapshot?> restoreFromCloud() async {
    final json = await _methods.invokeMethod<String>('restoreFromCloud');
    return json == null ? null : PhoneSnapshot.decode(json);
  }

  @override
  Future<void> setFavorites(List<Favorite> favorites) =>
      _methods.invokeMethod('setFavorites', {'favorites': jsonEncode(favorites)});

  @override
  Future<void> syncNow() => _methods.invokeMethod('syncNow');

  @override
  Future<PhoneSnapshot> setPush({required bool enabled, String url = ''}) async =>
      PhoneSnapshot.decode((await _methods.invokeMethod<String>('setPush', {'enabled': enabled, 'url': url}))!);

  @override
  Future<bool> watchConnected() async => await _methods.invokeMethod<bool>('watchConnected') ?? false;

  @override
  Future<StartResult> startTimer(Favorite favorite) async {
    final result = await _methods.invokeMethod<String>('startTimer', favorite.toJson());
    return result == 'toggl' ? StartResult.togglApp : StartResult.api;
  }

  @override
  Future<String> appVersion() async => await _methods.invokeMethod<String>('appVersion') ?? '';

  @override
  Future<void> openUrl(String url) => _methods.invokeMethod('openUrl', {'url': url});

  @override
  Future<bool> getCompact() async => await _methods.invokeMethod<bool>('getCompact') ?? false;

  @override
  Future<void> setCompact(bool compact) => _methods.invokeMethod('setCompact', {'compact': compact});
}
