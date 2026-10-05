import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trackwatch/src/format.dart';
import 'package:trackwatch/src/models.dart';

import 'fakes.dart';

void main() {
  test('parses the Kotlin ViewState JSON', () {
    final json = jsonEncode({
      'configured': true,
      'entries': [
        {'id': 'local-1', 'description': 'A', 'projectId': 5, 'start': 1000, 'stop': null, 'pending': true},
        {'id': '2', 'description': '', 'projectId': null, 'start': 0, 'stop': 500, 'pending': false},
      ],
      'projects': [
        {'id': 5, 'name': 'P', 'color': '#ff0000'},
      ],
      'favorites': [
        {'description': 'F', 'projectId': null},
      ],
      'acks': ['x'],
      'idMap': {'local-0': '1'},
      'pendingCount': 1,
      'lastSync': 42,
      'error': null,
      'rateLimitedUntil': null,
      'phoneReachable': false,
    });
    final state = ViewState.decode(json);
    expect(state.configured, isTrue);
    expect(state.running?.id, 'local-1');
    expect(state.running?.pending, isTrue);
    expect(state.project(5)?.name, 'P');
    expect(state.favorites.single, const Favorite(description: 'F'));
    expect(state.entries.last.duration(), const Duration(milliseconds: 500));
    expect(state.phoneReachable, isFalse);
    expect(state.lastSync, DateTime.fromMillisecondsSinceEpoch(42));
  });

  test('quota is only reported while its window is open', () {
    final now = DateTime(2026, 9, 26, 12);
    final state = ViewState.fromJson({
      'quotaRemaining': 27,
      'quotaResetsAt': now.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
    });
    expect(state.quotaRemaining, 27);
    expect(state.quotaLeft(now), 27);
    expect(state.quotaLeft(now.add(const Duration(minutes: 21))), isNull);
    expect(const ViewState().quotaLeft(now), isNull);
  });

  test('recents are distinct and newest first', () {
    final recents = sampleState().recents();
    expect(recents, const [
      Favorite(description: 'Coding', projectId: 1),
      Favorite(description: 'Standup', projectId: 2),
    ]);
  });

  test('recent timers: synced entries first, then the 30-day list, without the running timer', () {
    expect(sampleState().recentTimers(), const [
      Favorite(description: 'Standup', projectId: 2),
      Favorite(description: 'Review', projectId: 2),
      Favorite(description: 'Deep work', projectId: 1),
    ]);
    expect(sampleState(running: false).recentTimers().first, const Favorite(description: 'Standup', projectId: 2));
    expect(sampleState(running: false).recentTimers()[1], const Favorite(description: 'Coding', projectId: 1));
    expect(sampleState().recentTimers(limit: 2).length, 2);
  });

  test('days group entries with totals', () {
    final days = sampleState(running: false).days();
    expect(days.length, 2);
    expect(days.first.entries.single.description, 'Standup');
    expect(days.first.total(), const Duration(minutes: 15));
    expect(days.last.total(), const Duration(hours: 2));
  });

  test('formatting', () {
    expect(formatClock(const Duration(hours: 1, minutes: 4, seconds: 5)), '1:04:05');
    expect(formatTotal(const Duration(minutes: 12)), '12m');
    expect(formatTotal(const Duration(hours: 3, minutes: 7)), '3h 07m');
    expect(colorFromHex('#0b83d9').toARGB32(), 0xFF0B83D9);
    expect(colorFromHex('nope').toARGB32(), 0xFF9E9E9E);
  });
}
