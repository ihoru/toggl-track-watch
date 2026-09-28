import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackwatch/phone/phone_app.dart';
import 'package:trackwatch/phone/phone_bridge.dart';
import 'package:trackwatch/src/models.dart';

import 'fakes.dart';

void main() {
  testWidgets('token setup then favorites', (tester) async {
    final bridge = FakePhoneBridge(PhoneSnapshot.empty);
    await tester.pumpWidget(PhoneApp(bridge: bridge));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  abc123 ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(bridge.token, 'abc123');
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Deep work'), findsOneWidget);
    // Collapsed sync row, then the details.
    expect(find.textContaining('Watch ✓'), findsOneWidget);
    expect(find.textContaining('27 API left'), findsOneWidget);
    await tester.tap(find.textContaining('Watch ✓'));
    await tester.pumpAndSettle();
    expect(find.text('Watch connected'), findsOneWidget);
    expect(find.textContaining('27 Toggl API requests left'), findsOneWidget);

    await tester.tap(find.byTooltip('Add from recent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Standup'));
    await tester.pumpAndSettle();
    expect(bridge.savedFavorites?.last, const Favorite(description: 'Standup', projectId: 2));
  });

  testWidgets('add a favorite manually', (tester) async {
    final bridge = FakePhoneBridge(
      PhoneSnapshot(sampleState(), const Account(name: 'Ihor', email: '', workspace: 'WS')),
    );
    await tester.pumpWidget(PhoneApp(bridge: bridge));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add favorite'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Description'), 'Review');
    await tester.tap(find.byType(DropdownButtonFormField<int?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Client A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(bridge.savedFavorites?.last, const Favorite(description: 'Review', projectId: 1));
  });

  PhoneSnapshot signedIn() => PhoneSnapshot(sampleState(), const Account(name: 'Ihor', email: 'e@x', workspace: 'WS'));

  testWidgets('header shows the account and a change-token button', (tester) async {
    final bridge = FakePhoneBridge(signedIn());
    await tester.pumpWidget(PhoneApp(bridge: bridge));
    await tester.pumpAndSettle();

    expect(find.text('Ihor · WS'), findsOneWidget);
    await tester.tap(find.byTooltip('Change token'));
    await tester.pumpAndSettle();
    expect(find.text('Remove token?'), findsOneWidget);
  });

  testWidgets('swipe left asks before deleting a favorite', (tester) async {
    final bridge = FakePhoneBridge(signedIn());
    await tester.pumpWidget(PhoneApp(bridge: bridge));
    await tester.pumpAndSettle();

    await tester.drag(find.text('Deep work'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Delete favorite?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Deep work'), findsOneWidget);
    expect(bridge.savedFavorites, isNull);

    await tester.drag(find.text('Deep work'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Deep work'), findsNothing);
    expect(bridge.savedFavorites, const [Favorite(description: 'Email')]);
  });

  testWidgets('a short swipe does nothing', (tester) async {
    final bridge = FakePhoneBridge(signedIn());
    await tester.pumpWidget(PhoneApp(bridge: bridge));
    await tester.pumpAndSettle();

    await tester.drag(find.text('Deep work'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Delete favorite?'), findsNothing);
    expect(find.text('Deep work'), findsOneWidget);
  });

  testWidgets('swipe right starts the favorite and keeps it', (tester) async {
    final bridge = FakePhoneBridge(signedIn())..startResult = StartResult.togglApp;
    await tester.pumpWidget(PhoneApp(bridge: bridge));
    await tester.pumpAndSettle();

    await tester.drag(find.text('Deep work'), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(bridge.started, const [Favorite(description: 'Deep work', projectId: 1)]);
    expect(find.text('Deep work'), findsOneWidget);
    expect(find.text('Opening Toggl to start "Deep work"'), findsOneWidget);
  });

  testWidgets('compact view is a one-line row and is remembered', (tester) async {
    final bridge = FakePhoneBridge(signedIn());
    await tester.pumpWidget(PhoneApp(bridge: bridge));
    await tester.pumpAndSettle();
    expect(find.text('Client A'), findsWidgets);

    await tester.tap(find.byTooltip('Compact view'));
    await tester.pumpAndSettle();
    expect(bridge.compact, isTrue);
    expect(find.textContaining('Deep work  ·  Client A', findRichText: true), findsOneWidget);
    expect(find.byTooltip('Comfortable view'), findsOneWidget);
  });
}
