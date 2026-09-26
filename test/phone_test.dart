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
    expect(find.text('Watch connected'), findsOneWidget);
    expect(find.textContaining('27 Toggl API requests left'), findsOneWidget);

    await tester.tap(find.text('From recent'));
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
}
