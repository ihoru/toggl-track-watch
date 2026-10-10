import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackwatch/src/models.dart';
import 'package:trackwatch/wear/screens.dart';
import 'package:trackwatch/wear/wear_app.dart';

import 'fakes.dart';

Future<void> pumpWatch(WidgetTester tester, FakeWatchBridge bridge) async {
  tester.view.physicalSize = const Size(450, 450);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(WearApp(bridge: bridge));
  await settle(tester);
}

/// Lets transitions finish (pumpAndSettle never settles with ticking timers).
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(find.text(text), 50, scrollable: find.byType(Scrollable).hitTestable().last);
  await tester.ensureVisible(find.text(text));
  await tester.pump();
  await tester.tap(find.text(text));
  await settle(tester);
}

/// Swipes the pager one page to the left (to the next section).
Future<void> nextPage(WidgetTester tester) async {
  await tester.fling(find.byType(PageView), const Offset(-200, 0), 1000);
  await settle(tester);
}

void main() {
  testWidgets('six pages: now, favorites, history, recent, frequent, sync', (tester) async {
    final bridge = FakeWatchBridge(sampleState());
    await pumpWatch(tester, bridge);

    // Now
    expect(find.text('Coding'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    expect(bridge.calls, ['stop:10']);

    await nextPage(tester);
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Deep work'), findsOneWidget);

    await nextPage(tester);
    expect(find.textContaining('Today'), findsOneWidget);

    // Recent: newest first, favorites included, the running timer left out.
    await nextPage(tester);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Standup'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Deep work'), findsOneWidget);
    expect(find.text('Coding'), findsNothing);

    // Frequent (the phone has already left out favorites).
    await nextPage(tester);
    expect(find.text('Frequent · 30 days'), findsOneWidget);
    expect(find.text('Client A · ×12'), findsOneWidget);
    expect(find.text('Internal · ×5'), findsOneWidget);

    await nextPage(tester);
    expect(find.text('27 Toggl API requests left'), findsOneWidget);
    await tapText(tester, 'Refresh');
    expect(bridge.calls.last, 'refresh');
    await tapText(tester, 'Open on phone');
    expect(bridge.calls.last, 'openOnPhone');
    expect(find.text('Opened on phone'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Track Watch 1.1.0 (2)'), 50, scrollable: find.byType(Scrollable).last);
    expect(find.text('Track Watch 1.1.0 (2)'), findsOneWidget);

    // The last page is remembered.
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.uiState['page'], 5);
  });

  testWidgets('starting a favorite, recent or frequent timer jumps to the current timer', (tester) async {
    final bridge = FakeWatchBridge(sampleState(running: false));
    await pumpWatch(tester, bridge);
    expect(find.text('No timer running'), findsOneWidget);

    await nextPage(tester);
    await tapText(tester, 'Deep work');
    expect(bridge.calls.last, 'start:Deep work:1');
    expect(find.text('No timer running'), findsOneWidget);

    await nextPage(tester);
    await nextPage(tester);
    await nextPage(tester);
    await tapText(tester, 'Review');
    expect(bridge.calls.last, 'start:Review:2');
    expect(find.text('No timer running'), findsOneWidget);

    for (var i = 0; i < 4; i++) {
      await nextPage(tester);
    }
    await tapText(tester, 'Standup');
    expect(bridge.calls.last, 'start:Standup:2');
    expect(find.text('No timer running'), findsOneWidget);
  });

  testWidgets('now page: New timer first, then the three latest distinct timers', (tester) async {
    final bridge = FakeWatchBridge(sampleState(running: false));
    await pumpWatch(tester, bridge);

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    final labels = ['New timer', 'Standup', 'Coding', 'Review'];
    for (final l in labels) {
      await tester.scrollUntilVisible(find.text(l), 50, scrollable: find.byType(Scrollable).last);
    }
    expect(find.text('Deep work'), findsNothing);
    await tester.scrollUntilVisible(find.text('New timer'), -50, scrollable: find.byType(Scrollable).last);
    expect(top('New timer'), lessThan(top('Standup')));
    expect(top('Standup'), lessThan(top('Coding')));

    await tapText(tester, 'Review');
    expect(bridge.calls.last, 'start:Review:2');
  });

  testWidgets('now page with a running timer leaves it out of the recent timers', (tester) async {
    final bridge = FakeWatchBridge(sampleState());
    await pumpWatch(tester, bridge);
    // The whole list is built: Coding appears only on the running card.
    for (final l in ['Coding', 'New timer', 'Standup', 'Review', 'Deep work']) {
      expect(find.text(l, skipOffstage: false), findsOneWidget);
    }
  });

  testWidgets('remembers the last page across launches', (tester) async {
    final bridge = FakeWatchBridge(sampleState())..uiState = {'page': 4};
    await pumpWatch(tester, bridge);
    expect(find.text('Frequent · 30 days'), findsOneWidget);
  });

  testWidgets('cancel discards the running timer after confirmation', (tester) async {
    final bridge = FakeWatchBridge(sampleState());
    await pumpWatch(tester, bridge);

    await tapText(tester, 'Cancel');
    expect(find.text('Discard this timer?'), findsOneWidget);
    await tester.tap(find.byTooltip('No'));
    await settle(tester);
    expect(bridge.calls, isEmpty);

    await tapText(tester, 'Cancel');
    await tester.tap(find.byTooltip('Confirm'));
    await settle(tester);
    expect(bridge.calls.last, 'delete:10');
  });

  testWidgets('unconfigured watch offers to install or open the phone app', (tester) async {
    final bridge = FakeWatchBridge(const ViewState());
    await pumpWatch(tester, bridge);
    expect(find.textContaining('Install it on your phone'), findsOneWidget);

    await tapText(tester, 'Install on phone');
    expect(bridge.calls.last, 'openUrl:https://github.com/ihoru/toggl-track-watch/releases/latest');
    expect(find.text('Opened on phone'), findsOneWidget);

    bridge.phoneReachable = false;
    await tapText(tester, 'Open on phone');
    expect(bridge.calls.last, 'openOnPhone');
    expect(find.text('Phone not reachable'), findsOneWidget);
  });

  testWidgets('new timer with voice description and project', (tester) async {
    final bridge = FakeWatchBridge(sampleState(running: false))..nextText = 'Planning';
    await pumpWatch(tester, bridge);

    await tapText(tester, 'New timer');
    await tapText(tester, 'Add description');
    expect(find.text('Planning'), findsOneWidget);
    await tapText(tester, 'No project');
    await tapText(tester, 'Internal');
    await tapText(tester, 'Start');
    expect(bridge.calls.last, 'start:Planning:2');
    expect(find.text('Add description'), findsNothing);
    await tester.scrollUntilVisible(find.text('No timer running'), -50, scrollable: find.byType(Scrollable).last);
    expect(find.text('No timer running'), findsOneWidget);
  });

  testWidgets('history: edit, continue and delete an entry', (tester) async {
    final bridge = FakeWatchBridge(sampleState(running: false))..nextText = 'Retro';
    await pumpWatch(tester, bridge);
    await nextPage(tester);
    await nextPage(tester);

    expect(find.textContaining('Today'), findsOneWidget);
    await tapText(tester, 'Standup');

    await tapText(tester, 'Edit');
    await tapText(tester, 'Standup');
    await tapText(tester, 'Save');
    expect(bridge.calls.last, 'update:9:Retro:2');

    await tapText(tester, 'Delete');
    await tester.tap(find.byTooltip('Confirm'));
    await settle(tester);
    expect(bridge.calls.last, 'delete:9');

    await tapText(tester, 'Coding');
    await tapText(tester, 'Continue');
    expect(bridge.calls.last, 'start:Coding:1');
    expect(find.text('No timer running'), findsOneWidget);
  });

  testWidgets('ambient mode shows the low-power timer view', (tester) async {
    final bridge = FakeWatchBridge(sampleState());
    await pumpWatch(tester, bridge);

    bridge.setAmbient('enter');
    await tester.pump();
    await tester.pump();
    expect(find.text('0:05'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);

    bridge.setAmbient('exit');
    await tester.pump();
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('swiping right on the first page closes the app', (tester) async {
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpWatch(tester, FakeWatchBridge(sampleState()));

    // Right swipe on another page just goes back one page.
    await nextPage(tester);
    await tester.fling(find.byType(PageView), const Offset(200, 0), 1000);
    await settle(tester);
    expect(platformCalls, isNot(contains('SystemNavigator.pop')));

    // On the first page it closes the app.
    await tester.fling(find.byType(PageView), const Offset(200, 0), 1000);
    await settle(tester);
    expect(platformCalls, contains('SystemNavigator.pop'));
  });

  testWidgets('edit start time of the running timer', (tester) async {
    final state = sampleState();
    final start = state.running!.start;
    final bridge = FakeWatchBridge(state);
    await pumpWatch(tester, bridge);

    await tapText(tester, 'Coding');
    await tapText(tester, 'Edit start time');
    await tapText(tester, '−15');
    await tapText(tester, '−5');
    await tapText(tester, 'Save');
    final expected = start.subtract(const Duration(minutes: 20));
    expect(bridge.calls.last, 'setStart:10:${expected.millisecondsSinceEpoch}');

    // Can't move the start into the future.
    await tapText(tester, 'Edit start time');
    await tapText(tester, '+15');
    await tapText(tester, 'Save');
    final saved = int.parse(bridge.calls.last.split(':').last);
    expect(saved, lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch));
    expect(saved, greaterThan(start.millisecondsSinceEpoch));
  });

  testWidgets('history: edit start and end time of a stopped entry', (tester) async {
    final state = sampleState(running: false);
    final entry = state.entry('8')!;
    final bridge = FakeWatchBridge(state);
    await pumpWatch(tester, bridge);
    for (var i = 0; i < 2; i++) {
      await nextPage(tester);
    }
    await tapText(tester, 'Coding');

    await tapText(tester, 'Edit end time');
    expect(find.text('End time'), findsOneWidget);
    await tapText(tester, '−15');
    await tapText(tester, 'Save');
    expect(bridge.calls.last, 'setStop:8:${entry.stop!.subtract(const Duration(minutes: 15)).millisecondsSinceEpoch}');

    // The end can't move before the start.
    await tapText(tester, 'Edit end time');
    for (var i = 0; i < 10; i++) {
      await tapText(tester, '−15');
    }
    await tapText(tester, 'Save');
    expect(bridge.calls.last, 'setStop:8:${entry.start.millisecondsSinceEpoch}');

    await tapText(tester, 'Edit start time');
    await tapText(tester, '−5');
    await tapText(tester, 'Save');
    expect(bridge.calls.last, 'setStart:8:${entry.start.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch}');

    // The start can't move past the end.
    await tapText(tester, 'Edit start time');
    for (var i = 0; i < 10; i++) {
      await tapText(tester, '+15');
    }
    await tapText(tester, 'Save');
    expect(bridge.calls.last, 'setStart:8:${entry.stop!.millisecondsSinceEpoch}');
  });

  testWidgets('an offline entry stays open once it gets its Toggl id', (tester) async {
    final start = DateTime.now().subtract(const Duration(hours: 1));
    TimeEntry entry(String id, DateTime start) => TimeEntry(
      id: id,
      description: 'Offline',
      projectId: null,
      start: start,
      stop: start.add(const Duration(minutes: 30)),
    );
    final bridge = FakeWatchBridge(ViewState(configured: true, entries: [entry('local-1', start)]));
    await pumpWatch(tester, bridge);
    for (var i = 0; i < 2; i++) {
      await nextPage(tester);
    }
    await tapText(tester, 'Offline');

    // Synced with an edited start time: found through the id map, not by start.
    final moved = start.subtract(const Duration(minutes: 5));
    bridge.emit(ViewState(configured: true, entries: [entry('77', moved)], idMap: const {'local-1': '77'}));
    await settle(tester);
    expect(find.text('Entry deleted'), findsNothing);
    await tapText(tester, 'Edit end time');
    expect(find.text('End time'), findsOneWidget);
  });

  testWidgets('a running timer has no end time to edit', (tester) async {
    await pumpWatch(tester, FakeWatchBridge(sampleState()));
    await tapText(tester, 'Coding');
    expect(find.text('Edit start time'), findsOneWidget);
    expect(find.text('Edit end time'), findsNothing);
  });

  testWidgets('settings: toggles are saved and the crown step applies', (tester) async {
    final state = sampleState();
    final start = state.running!.start;
    final bridge = FakeWatchBridge(state);
    await pumpWatch(tester, bridge);
    for (var i = 0; i < 5; i++) {
      await nextPage(tester);
    }

    await tapText(tester, 'Settings');
    await tapText(tester, 'Timer notification');
    expect(bridge.settings['ongoing'], false);
    await tapText(tester, 'Vibration');
    expect(bridge.settings['haptics'], false);
    await tapText(tester, 'Crown step: 1 min');
    expect(bridge.settings['crownStep'], 5);
    expect(find.text('Crown step: 5 min'), findsOneWidget);
    await tapText(tester, 'Source code');
    expect(bridge.calls.last, 'openUrl:https://github.com/ihoru/toggl-track-watch');

    // Back to Now, open the start-time editor and turn the crown two steps back: 10 minutes.
    Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
    await settle(tester);
    for (var i = 0; i < 5; i++) {
      await tester.fling(find.byType(PageView), const Offset(200, 0), 1000);
      await settle(tester);
    }
    await tapText(tester, 'Coding');
    await tapText(tester, 'Edit start time');
    bridge.turnCrown(-40);
    await settle(tester);
    await tapText(tester, 'Save');
    final expected = start.subtract(const Duration(minutes: 10));
    expect(bridge.calls.last, 'setStart:10:${expected.millisecondsSinceEpoch}');
  });

  testWidgets('saved settings are loaded on start', (tester) async {
    final bridge = FakeWatchBridge(sampleState())..settings.addAll({'crownStep': 5, 'haptics': false});
    await pumpWatch(tester, bridge);
    for (var i = 0; i < 5; i++) {
      await nextPage(tester);
    }
    await tapText(tester, 'Settings');
    expect(find.text('Crown step: 5 min'), findsOneWidget);
    final vibration = tester.widget<Switch>(
      find.descendant(of: find.widgetWithText(InkWell, 'Vibration'), matching: find.byType(Switch)),
    );
    expect(vibration.value, isFalse);
  });
}
