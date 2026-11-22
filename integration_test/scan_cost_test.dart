// Measures how much work scanning causes on the Dart side: the number of
// controller notifications (each one rebuilds listening widgets) over a fixed
// time while scanning, with at least one advertising peer nearby.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/scan_cost_test.dart -d <device-id>

import 'package:bluetooth_communicator/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_helpers.dart';

const measureFor = Duration(seconds: 20);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scan cost', (tester) async {
    final controller = BleAppController();
    await tester.pumpWidget(MyApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle();
    await ensureBleModesEnabled(tester);
    // Let the scan start and the first results come in.
    await tester.pump(const Duration(seconds: 5));

    var notifications = 0;
    void count() => notifications++;
    controller.addListener(count);
    final end = DateTime.now().add(measureFor);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    controller.removeListener(count);

    debugPrint(
      'IT_RESULT notifications in ${measureFor.inSeconds}s: $notifications, '
      'nearby devices: ${controller.discoveredDevices.length}',
    );
  });
}
