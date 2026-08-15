import 'package:easy_send_app/src/rust/api/simple.dart';
import 'package:easy_send_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('Dart에서 Rust 함수 호출 왕복', (WidgetTester tester) async {
    expect(greet(name: 'Tom'), 'Hello, Tom!');
  });
}
