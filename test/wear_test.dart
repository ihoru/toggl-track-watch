import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackwatch/src/models.dart';
import 'package:trackwatch/wear/wear_app.dart';

import 'fakes.dart';

Future<void> pumpWatch(WidgetTester tester, FakeWatchBridge bridge) async {
  tester.view.physicalSize = const Size(450, 450);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(WearApp(bridge: bridge));
  await tester.pump();
}

/// Lets route transitions finish (pumpAndSettle never settles with ticking timers).
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(find.text(text), 50);
  await tester.ensureVisible(find.text(text));
  await tester.pump();
  await tester.tap(find.text(text));
  await settle(tester);
}

void main() {
  testWidgets('home shows running timer, favorites and recents', (tester) async {
    final bridge = FakeWatchBridge(sampleState());
    await pumpWatch(tester, bridge);

    expect(find.text('Coding'), findsWidgets);
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    expect(bridge.calls, ['stop:10']);

    await tapText(tester, 'Deep work');
    expect(bridge.calls.last, 'start:Deep work:1');

    // "Coding" is not a favorite, so it appears under Recent.
    await tester.scrollUntilVisible(find.text('Recent'), 50);
    expect(find.text('Standup'), findsOneWidget);
  });

  testWidgets('unconfigured watch asks to set up the phone', (tester) async {
    await pumpWatch(tester, FakeWatchBridge(const ViewState()));
    expect(find.textContaining('add your Toggl API token'), findsOneWidget);
  });

  testWidgets('new timer with voice description and project', (tester) async {
    final bridge = FakeWatchBridge(sampleState(running: false))..nextText = 'Planning';
    await pumpWatch(tester, bridge);
    expect(find.text('No timer running'), findsOneWidget);

    await tapText(tester, 'New timer');
    await tapText(tester, 'Add description');
    expect(find.text('Planning'), findsOneWidget);
    await tapText(tester, 'No project');
    await tapText(tester, 'Internal');
    await tapText(tester, 'Start');
    expect(bridge.calls.last, 'start:Planning:2');
    // Back on the home screen.
    expect(find.text('New timer'), findsOneWidget);
    expect(find.text('Add description'), findsNothing);
  });

  testWidgets('history: edit, continue and delete an entry', (tester) async {
    final bridge = FakeWatchBridge(sampleState(running: false))..nextText = 'Retro';
    await pumpWatch(tester, bridge);

    await tapText(tester, 'History');
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
  });
}
