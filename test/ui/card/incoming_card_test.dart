import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/platform/platform_service.dart';
import 'package:vayu/ui/card/incoming_card_watcher.dart';
import 'package:vayu/ui/card/vayu_card_view.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

class _Platform extends PlatformService {
  final opened = <Uri>[];

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: false,
        supportsBleAdvertising: false,
        supportsWifiDirect: false,
        supportsNfc: true,
        hasCamera: false,
      );

  @override
  Future<bool> isBleSupported() async => false;

  @override
  Future<bool> isWifiDirectSupported() async => false;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> openUri(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

const _card = VayuCard(
  name: 'Riya Sen',
  title: 'Designer',
  company: 'Achyrio',
  phone: '+91 98765 43210',
  email: 'riya@example.com',
  website: 'riya.design',
  accent: 3,
);

void main() {
  group('card colour and links', () {
    test('the sender\'s colour travels in the vCard', () {
      final parsed = ContactCard.tryParse(_card.toVcard())!;
      expect(parsed.style, 3);
      expect(CardFace.fromContact(parsed).accent, 3);
    });

    test('cards without a Vayu colour, or a bad one, use the default', () {
      final plain = ContactCard.tryParse(
        Uint8List.fromList(
          'BEGIN:VCARD\r\nFN:A\r\nX-VAYU-STYLE:999\r\nEND:VCARD\r\n'.codeUnits,
        ),
      )!;
      expect(plain.style, isNull);
      expect(CardFace.fromContact(plain).accent, 0);
    });

    test('phone, email and website become dialer, mail and browser links', () {
      final face = CardFace.fromContact(ContactCard.tryParse(_card.toVcard())!);
      expect(face.phoneUri.toString(), 'tel:+919876543210');
      expect(face.emailUri.toString(), 'mailto:riya@example.com');
      expect(face.websiteUri.toString(), 'https://riya.design');
    });
  });

  group('Save / Reject sheet', () {
    late AppContainer container;
    late _Platform platform;

    Future<void> open(WidgetTester tester) async {
      platform = _Platform();
      await tester.runAsync(() async {
        container = AppContainer.standard(
          storage: InMemoryIdentityStorage(
            LocalDeviceIdentity(
              deviceId: Uint8List.fromList(List.filled(16, 7)),
              displayName: 'Me',
              platform: 'android',
              createdAt: DateTime.now(),
            ),
          ),
          platformService: platform,
        );
        await container.initialize();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: VayuTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showIncomingCardSheet(
                  context,
                  container: container,
                  vcard: _card.toVcard(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    tearDown(() => container.dispose());

    testWidgets('Reject keeps nothing', (tester) async {
      await open(tester);
      expect(find.text('Card received'), findsOneWidget);
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      expect(container.receivedCards!.all, isEmpty);
    });

    testWidgets('Save puts the card in card history', (tester) async {
      await open(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // The card file is written with real I/O.
      for (var i = 0; i < 60 && container.receivedCards!.all.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Saved to your card history.'), findsOneWidget);
      expect(container.receivedCards!.all.single.name, 'Riya Sen');
    });

    testWidgets('long-pressing the card offers call and email', (tester) async {
      await open(tester);
      // Links live behind a long-press on the card.
      await tester.longPress(find.text('Riya Sen').first);
      await tester.pumpAndSettle();
      // Icons only around the card; no save or delete for an incoming card.
      expect(find.byTooltip('Delete'), findsNothing);
      expect(find.byTooltip('Website'), findsOneWidget);
      await tester.tap(find.byTooltip('Email'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Riya Sen').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Call'));
      await tester.pumpAndSettle();
      expect(platform.opened.map((u) => u.scheme), ['mailto', 'tel']);
    });
  });
}
