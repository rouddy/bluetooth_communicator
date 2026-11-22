// Host-side driver for `flutter drive`. `flutter test integration_test/...`
// can't start apps on wirelessly connected iOS devices, so on-device tests run
// through:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/app_test.dart -d <device-id>
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
