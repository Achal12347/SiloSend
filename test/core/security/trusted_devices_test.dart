import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/trust_record_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/security/trust_level.dart';
import 'package:vayu/ui/security/trusted_devices_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

import '../../ui/home/vayu_home_page_test.dart' show MockDiscoveryService;

Uint8List _key(int seed) => Uint8List.fromList(List.filled(32, seed));

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

void main() {
  group('trust store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('vayu_trust_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('names are kept and survive a restart; forgetting removes the '
        'pinned key for good', () async {
      final file = File('${dir.path}/trust.json');
      final store = PeerTrustStore(storage: FileTrustRecordStorage(file));
      await store.evaluatePeer(
        deviceIdHex: 'aa' * 16,
        presentedIdentityPubKey: _key(1),
      );
      await store.rememberName('aa' * 16, 'Ana’s phone');

      final reloaded = PeerTrustStore(storage: FileTrustRecordStorage(file));
      await reloaded.load();
      expect(reloaded.records['aa' * 16]!.displayName, 'Ana’s phone');

      expect(await reloaded.forget('AA' * 16), isTrue);
      final again = PeerTrustStore(storage: FileTrustRecordStorage(file));
      await again.load();
      expect(again.getTrustLevel('aa' * 16), isNull);
      // A new key is now a first contact, not a conflict.
      expect(
        await again.evaluatePeer(
          deviceIdHex: 'aa' * 16,
          presentedIdentityPubKey: _key(2),
        ),
        TrustLevel.unverifiedTOFU,
      );
    });

    test('files saved before names were kept still load', () async {
      final file = File('${dir.path}/trust.json')
        ..writeAsStringSync(
          jsonEncode({
            'version': 1,
            'peers': [
              {
                'deviceId': 'bb' * 16,
                'identityPubKey': base64Encode(_key(3)),
                'trustLevel': 'trustedTOFU',
                'firstSeen': DateTime.utc(2026).toIso8601String(),
                'lastSeen': DateTime.utc(2026).toIso8601String(),
              },
            ],
          }),
        );
      final store = PeerTrustStore(storage: FileTrustRecordStorage(file));
      await store.load();
      expect(store.records['bb' * 16]!.displayName, isNull);
      expect(store.getTrustLevel('bb' * 16), TrustLevel.trustedTOFU);
    });
  });

  test('two phones: the name is recorded when they connect; forgetting '
      'closes the session and drops the key', () async {
    Future<(AppContainer, LanConnectionServer)> phone(String name) async {
      final server = LanConnectionServer(requestedPort: 0);
      await server.start();
      final app = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity.generate(displayName: name, platform: 'android'),
        ),
        lanServer: server,
        discoveryCoordinator: DiscoveryCoordinator(
          services: [MockDiscoveryService(TransportType.lan)],
        ),
      );
      await app.initialize();
      return (app, server);
    }

    final (ana, anaServer) = await phone('Ana');
    final (bo, boServer) = await phone('Bo');
    try {
      ana.fileSharingCoordinator.rememberPeer(
        DiscoveredPeer(
          deviceId: bo.identity!.idHex,
          displayName: 'Bo',
          transportType: TransportType.lan,
          availableTransports: const {TransportType.lan},
          rssi: 0,
          endpointAddress: '127.0.0.1:${boServer.boundPort}',
          transportEndpoints: {
            TransportType.lan: '127.0.0.1:${boServer.boundPort}',
          },
          lastSeen: DateTime.now(),
        ),
      );
      await ana.chatService.send(
        deviceId: bo.identity!.idHex,
        peerName: 'Bo',
        text: 'hi',
      );
      final boId = bo.identity!.idHex.toLowerCase();
      await _until(() => ana.trustStore.records[boId]?.displayName == 'Bo');

      await ana.forgetDevice(boId);
      expect(ana.trustStore.getTrustLevel(boId), isNull);
      await _until(
        () => ana.secureSessionManager.getSessionForPeer(boId) == null,
      );
    } finally {
      ana.dispose();
      bo.dispose();
      await anaServer.stop();
      await boServer.stop();
    }
  });

  group('screen', () {
    late AppContainer app;

    Future<void> pump(WidgetTester tester, {double textScale = 1}) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        app = AppContainer.standard(
          storage: InMemoryIdentityStorage(
            LocalDeviceIdentity.generate(
              displayName: 'Tester',
              platform: 'android',
            ),
          ),
        );
        await app.initialize();
      });
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: VayuTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: TrustedDevicesPage(container: app),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    Future<void> meet(WidgetTester tester, String id, int seed, String name) =>
        tester.runAsync(() async {
          await app.trustStore.evaluatePeer(
            deviceIdHex: id,
            presentedIdentityPubKey: _key(seed),
          );
          await app.trustStore.rememberName(id, name);
        });

    testWidgets('empty: says so honestly', (tester) async {
      await pump(tester);
      expect(find.textContaining('No phones yet'), findsOneWidget);
      expect(find.text('This phone'), findsOneWidget);
    });

    testWidgets('lists real records, a key warning first; Forget asks, '
        'then removes', (tester) async {
      await pump(tester);
      await meet(tester, 'aa' * 16, 1, 'Ana');
      await meet(tester, 'bb' * 16, 2, 'Bo');
      // Bo shows up with a different key: a conflict.
      await tester.runAsync(() async {
        try {
          await app.trustStore.evaluatePeer(
            deviceIdHex: 'bb' * 16,
            presentedIdentityPubKey: _key(9),
          );
        } catch (_) {}
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Security warning'), findsOneWidget);
      final rows = find.byType(ListTile);
      expect(
        tester.getTopLeft(find.text('Bo')).dy,
        lessThan(tester.getTopLeft(find.text('Ana')).dy),
      );
      expect(rows, findsNWidgets(2));

      await tester.tap(find.text('Ana'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to verify'), findsOneWidget);
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(find.text('Forget Ana?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(app.trustStore.getTrustLevel('aa' * 16), isNull);
      expect(find.text('Ana'), findsNothing);
    });

    testWidgets('at 2x text nothing overflows', (tester) async {
      await pump(tester, textScale: 2);
      await meet(tester, 'cc' * 16, 4, 'A phone with a really long name');
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      final row = find.text('A phone with a really long name');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(find.ancestor(of: row, matching: find.byType(ListTile)));
      await tester.pumpAndSettle();
      // The sheet really opened, so its layout was checked too.
      expect(find.text('Key fingerprint'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
