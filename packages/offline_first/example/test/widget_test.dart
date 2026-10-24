import 'package:flutter_test/flutter_test.dart';
import 'package:offline_first_example/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('demo page renders app bar and buttons', (tester) async {
    await tester.pumpWidget(const OfflineFirstDemoApp());
    await tester.pump();

    expect(find.text('offline_first demo'), findsOneWidget);
  });
}
