import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/constants/app_constants.dart';
import 'package:silosend_datasharing_app/main.dart';

void main() {
  testWidgets('SiloSendApp mounts and displays truthful foundation state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SiloSendApp());

    // Verify app name is displayed
    expect(find.text(AppConstants.appName), findsWidgets);

    // Verify application identifier and minimum target
    expect(find.text(AppConstants.applicationId), findsOneWidget);
    expect(find.text('Android (API 26+)'), findsOneWidget);
    expect(find.text('Core Foundation Initialized'), findsOneWidget);
  });
}
