import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_flow_app/app.dart';

void main() {
  testWidgets('shows local-only dictation onboarding', (tester) async {
    await tester.pumpWidget(const LocalFlowApp());
    expect(find.text('On-device dictation'), findsOneWidget);
    expect(find.textContaining('Audio, models, history'), findsOneWidget);
  });

  testWidgets('exposes a single primary setup action plus hints', (tester) async {
    // Tall surface so the whole (lazy) ListView is laid out without scrolling.
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LocalFlowApp());
    await tester.pump();

    // One primary button drives the whole setup.
    expect(find.widgetWithText(FilledButton, 'Get started'), findsOneWidget);

    // Onboarding hints are present.
    expect(find.text('How it works'), findsOneWidget);
    expect(find.text('Tap Get started'), findsOneWidget);
    expect(find.text('Enable the keyboard'), findsOneWidget);
    expect(find.text('Hold to talk'), findsOneWidget);

    // Power-user controls stay collapsed behind Advanced.
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Reload models'), findsNothing);

    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Reload models'), findsOneWidget);

    // Hub entry appears only after the native engine opens (not in this harness).
    expect(find.text('Hub'), findsNothing);
  });
}
