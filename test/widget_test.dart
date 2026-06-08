import 'package:flutter_test/flutter_test.dart';
import 'package:obd2_trip_planner/main.dart';

void main() {
  testWidgets('App boot test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const DriveSyncApp());

    // Verify that our app widget was created.
    expect(find.byType(DriveSyncApp), findsOneWidget);
  });
}
