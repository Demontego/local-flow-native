import 'package:flutter_test/flutter_test.dart';

import 'package:local_flow_app/app.dart';

void main() {
  testWidgets('shows local-only dictation onboarding', (tester) async {
    await tester.pumpWidget(const LocalFlowApp());
    expect(find.text('On-device dictation'), findsOneWidget);
    expect(find.textContaining('Audio, models, history'), findsOneWidget);
  });
}
