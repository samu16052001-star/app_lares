import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app_lares/main.dart';

void main() {
  testWidgets('opens the user section with the user code', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LaresApp());

    expect(find.text('Enter your access code'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'user');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to the user section!'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    expect(find.text('Scanning Bluetooth Devices'), findsWidgets);
  });

  testWidgets('opens the researcher section with the researcher code', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LaresApp());

    await tester.enterText(find.byType(EditableText), 'researcher');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to the researcher section!'), findsOneWidget);
  });

  testWidgets('opens the developer section with the developer code', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LaresApp());

    await tester.enterText(find.byType(EditableText), 'developer');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to the developer section!'), findsOneWidget);
  });

  testWidgets('shows an error for an invalid code', (WidgetTester tester) async {
    await tester.pumpWidget(const LaresApp());

    await tester.enterText(find.byType(EditableText), 'wrong-code');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.text('Invalid code. Please try again.'), findsOneWidget);
  });
}
