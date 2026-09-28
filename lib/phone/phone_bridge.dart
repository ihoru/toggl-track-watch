import 'dart:convert';

import 'package:flutter/services.dart';

import '../src/models.dart';

class Account {
  const Account({required this.name, required this.email, required this.workspace});

  final String name;
  final String email;
  final String workspace;
}

class PhoneSnapshot {
  const PhoneSnapshot(this.state, this.account);

  final ViewState state;
  final Account? account;

  static const empty = PhoneSnapshot(ViewState.empty, null);

  factory PhoneSnapshot.decode(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    final account = json['account'] as Map<String, dynamic>?;
    return PhoneSnapshot(
      ViewState.fromJson(json['state'] as Map<String, dynamic>),
      account == null
          ? null
          : Account(
              name: account['name'] as String? ?? '',
              email: account['email'] as String? ?? '',
              workspace: account['workspace'] as String? ?? '',
            ),
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
  Future<void> setFavorites(List<Favorite> favorites);
  Future<void> syncNow();
  Future<bool> watchConnected();

  /// Installed app version, e.g. "1.1.0 (2)".
  Future<String> appVersion();

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
  Future<void> setFavorites(List<Favorite> favorites) =>
      _methods.invokeMethod('setFavorites', {'favorites': jsonEncode(favorites)});

  @override
  Future<void> syncNow() => _methods.invokeMethod('syncNow');

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
  Future<bool> getCompact() async => await _methods.invokeMethod<bool>('getCompact') ?? false;

  @override
  Future<void> setCompact(bool compact) => _methods.invokeMethod('setCompact', {'compact': compact});
}
