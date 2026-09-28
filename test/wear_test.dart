import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackwatch/src/models.dart';
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
  testWidgets('five pages: now, favorites, frequent, history, sync', (tester) async {
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
    expect(find.text('Frequent · 30 days'), findsOneWidget);
    expect(find.text('Client A · ×12'), findsOneWidget);
    expect(find.text('Internal · ×5'), findsOneWidget);

    await nextPage(tester);
    expect(find.textContaining('Today'), findsOneWidget);

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
    expect(bridge.uiState['page'], 4);
  });

  testWidgets('starting a favorite or frequent timer jumps to the current timer', (tester) async {
    final bridge = FakeWatchBridge(sampleState(running: false));
    await pumpWatch(tester, bridge);
    expect(find.text('No timer running'), findsOneWidget);

    await nextPage(tester);
    await tapText(tester, 'Deep work');
    expect(bridge.calls.last, 'start:Deep work:1');
    expect(find.text('No timer running'), findsOneWidget);

    await nextPage(tester);
    await nextPage(tester);
    await tapText(tester, 'Standup');
    expect(bridge.calls.last, 'start:Standup:2');
    expect(find.text('No timer running'), findsOneWidget);
  });

  testWidgets('remembers the last page across launches', (tester) async {
    final bridge = FakeWatchBridge(sampleState())..uiState = {'page': 2};
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

  testWidgets('unconfigured watch asks to set up the phone', (tester) async {
    await pumpWatch(tester, FakeWatchBridge(const ViewState()));
    expect(find.textContaining('add your Toggl API token'), findsOneWidget);
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
    expect(find.text('No timer running'), findsOneWidget);
  });

  testWidgets('history: edit, continue and delete an entry', (tester) async {
    final bridge = FakeWatchBridge(sampleState(running: false))..nextText = 'Retro';
    await pumpWatch(tester, bridge);
    for (var i = 0; i < 3; i++) {
      await nextPage(tester);
    }

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
    await tapText(tester, '−5');
    await tapText(tester, '−1');
    await tapText(tester, 'Save');
    final expected = start.subtract(const Duration(minutes: 6));
    expect(bridge.calls.last, 'setStart:10:${expected.millisecondsSinceEpoch}');

    // Can't move the start into the future.
    await tapText(tester, 'Edit start time');
    for (var i = 0; i < 3; i++) {
      await tapText(tester, '+5');
    }
    await tapText(tester, 'Save');
    final saved = int.parse(bridge.calls.last.split(':').last);
    expect(saved, lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch));
    expect(saved, greaterThan(start.millisecondsSinceEpoch));
  });
}
