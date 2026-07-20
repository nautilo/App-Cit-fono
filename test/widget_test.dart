import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:citofono_app/main.dart';

void main() {
  testWidgets('shows login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const CitofonoApp());

    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Ingresar'), findsOneWidget);
  });
}
