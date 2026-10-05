import 'package:flutter_test/flutter_test.dart';

void configureOwnerAuthBinding(
  TestWidgetsFlutterBinding binding, {
  required bool manualStart,
}) {
  // Live test bindings otherwise drop physical taps, unlike tester.tap.
  binding.shouldPropagateDevicePointerEvents = manualStart;
}
