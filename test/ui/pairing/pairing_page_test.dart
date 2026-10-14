import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/pairing/pairing_page.dart';
import 'package:vayu/ui/pairing/qr_code_view.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

void main() {
  late AppContainer container;

  setUp(() async {
    final server = LanConnectionServer(requestedPort: 0);
    await server.start();
    container = AppContainer.standard(
      storage: InMemoryIdentityStorage(
        LocalDeviceIdentity.generate(displayName: 'Pixel', platform: 'android'),
      ),
      lanServer: server,
    );
    await container.initialize();
  });

  tearDown(() async {
    await container.lanServer?.stop();
    container.dispose();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    PairingMode mode = PairingMode.show,
    Future<String?> Function()? scan,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        home: PairingPage(
          container: container,
          initialMode: mode,
          scanOverride: scan,
        ),
      ),
    );
    // Building the code reads real network interfaces.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
  }

  testWidgets('show mode renders a scannable code with a copyable link', (
    tester,
  ) async {
    await pumpPage(tester);
    final hasAddress = find.byType(QrCodeView).evaluate().isNotEmpty;
    if (hasAddress) {
      expect(find.text('Copy pairing link'), findsOneWidget);
      expect(find.text('Pixel'), findsOneWidget);
    } else {
      // Host without a usable interface: an honest explanation instead of a dead code.
      expect(find.textContaining('direct Wi-Fi'), findsWidgets);
    }
    expect(find.text('Not on the same Wi-Fi?'), findsOneWidget);
  });

  testWidgets('a pasted non-link explains what to paste', (tester) async {
    await pumpPage(tester, mode: PairingMode.join);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.text('Join with link'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.textContaining('vayu://pair link'), findsOneWidget);
  });

  testWidgets('closing the scanner without a code changes nothing', (
    tester,
  ) async {
    await pumpPage(tester, mode: PairingMode.join, scan: () async => null);
    await tester.tap(find.text('Scan code'));
    await tester.pump();
    expect(find.text('Pair a phone'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
  });
}
