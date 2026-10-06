import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/pairing/nfc_pairing_service.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/platform/platform_service.dart';

class _FakePlatformService extends PlatformService {
  final DeviceCapabilities capabilities;

  _FakePlatformService({required this.capabilities});

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async => capabilities;

  @override
  Future<bool> isBleSupported() async => capabilities.supportsBle;

  @override
  Future<bool> isWifiDirectSupported() async => capabilities.supportsWifiDirect;

  @override
  Future<bool> requestPermissions() async => true;
}

class _TestNfcAdapter implements NfcPlatformAdapter {
  bool available = true;
  bool enabled = true;
  void Function(Uint8List ndefBytes)? tagCallback;
  Uint8List? lastWrittenBytes;
  bool listening = false;

  @override
  Future<bool> isNfcAvailable() async => available;

  @override
  Future<bool> isNfcEnabled() async => enabled;

  @override
  Future<void> startListening({
    required void Function(Uint8List ndefBytes) onTagDiscovered,
  }) async {
    listening = true;
    tagCallback = onTagDiscovered;
  }

  @override
  Future<void> stopListening() async {
    listening = false;
    tagCallback = null;
  }

  @override
  Future<void> writeNdef(Uint8List ndefBytes) async {
    lastWrittenBytes = ndefBytes;
  }
}

void main() {
  group('NfcPairingService Truthful Capability & Operation Tests', () {
    const validHexId = '0123456789abcdef0123456789abcdef';
    const validToken = 'tok-1234567890abcdef1234567890ab';

    test(
      'truthfully reports unavailable when NFC hardware is unsupported',
      () async {
        final platform = _FakePlatformService(
          capabilities: const DeviceCapabilities(
            nfc: CapabilityStatus.unsupported,
          ),
        );
        final service = NfcPairingService(platformService: platform);

        expect(await service.isNfcAvailable, isFalse);

        final readResult = await service.startReading();
        expect(readResult.status, NfcOperationStatus.hardwareUnsupported);

        final writeResult = await service.writePayload(
          PairingPayload(
            deviceIdHex: validHexId,
            displayName: 'Test',
            pairingToken: validToken,
          ),
        );
        expect(writeResult.status, NfcOperationStatus.hardwareUnsupported);

        await service.dispose();
      },
    );

    test(
      'truthfully reports unavailable when NFC hardware is unknown (unprobed)',
      () async {
        final platform = _FakePlatformService(
          capabilities: const DeviceCapabilities(nfc: CapabilityStatus.unknown),
        );
        final service = NfcPairingService(platformService: platform);

        expect(await service.isNfcAvailable, isFalse);
        final result = await service.startReading();
        expect(result.status, NfcOperationStatus.hardwareUnsupported);

        await service.dispose();
      },
    );

    test(
      'reports disabled when hardware is present but turned off in settings',
      () async {
        final platform = _FakePlatformService(
          capabilities: const DeviceCapabilities(
            nfc: CapabilityStatus.supported,
          ),
        );
        final adapter = _TestNfcAdapter()
          ..available = true
          ..enabled = false;

        final service = NfcPairingService(
          platformService: platform,
          platformAdapter: adapter,
        );

        final result = await service.startReading();
        expect(result.status, NfcOperationStatus.hardwareDisabled);

        await service.dispose();
      },
    );

    test(
      'reads incoming NDEF tag and emits validated PairingPayload',
      () async {
        final platform = _FakePlatformService(
          capabilities: const DeviceCapabilities(
            nfc: CapabilityStatus.supported,
          ),
        );
        final adapter = _TestNfcAdapter();

        final service = NfcPairingService(
          platformService: platform,
          platformAdapter: adapter,
        );

        final payloadFuture = service.onPayloadReceived.first;

        final readResult = await service.startReading();
        expect(readResult.status, NfcOperationStatus.success);
        expect(service.status, NfcOperationStatus.listening);

        // Simulate incoming physical tag read
        final incomingPayload = PairingPayload(
          deviceIdHex: validHexId,
          displayName: 'SenderDevice',
          pairingToken: validToken,
          lanAddress: '192.168.1.55',
          lanPort: 53531,
        );
        adapter.tagCallback!(incomingPayload.toNdefBytes());

        final received = await payloadFuture;
        expect(received.deviceIdHex, validHexId);
        expect(received.displayName, 'SenderDevice');
        expect(received.pairingToken, validToken);
        expect(received.lanAddress, '192.168.1.55');
        expect(received.lanPort, 53531);

        await service.stopListening();
        expect(service.status, NfcOperationStatus.idle);
        await service.dispose();
      },
    );

    test('writes PairingPayload as standard NDEF record', () async {
      final platform = _FakePlatformService(
        capabilities: const DeviceCapabilities(nfc: CapabilityStatus.supported),
      );
      final adapter = _TestNfcAdapter();

      final service = NfcPairingService(
        platformService: platform,
        platformAdapter: adapter,
      );

      final payloadToWrite = PairingPayload(
        deviceIdHex: validHexId,
        displayName: 'BroadcastingDevice',
        pairingToken: validToken,
        lanAddress: '192.168.2.1',
        lanPort: 53531,
      );

      final writeResult = await service.writePayload(payloadToWrite);
      expect(writeResult.isSuccess, isTrue);
      expect(adapter.lastWrittenBytes, isNotNull);

      // Verify written bytes can be parsed back into identical payload
      final decoded = PairingPayload.fromNdefBytes(adapter.lastWrittenBytes!);
      expect(decoded.deviceIdHex, validHexId);
      expect(decoded.displayName, 'BroadcastingDevice');
      expect(decoded.lanAddress, '192.168.2.1');

      await service.dispose();
    });

    test(
      'handles malformed NDEF tag bytes gracefully without crashing',
      () async {
        final platform = _FakePlatformService(
          capabilities: const DeviceCapabilities(
            nfc: CapabilityStatus.supported,
          ),
        );
        final adapter = _TestNfcAdapter();

        final service = NfcPairingService(
          platformService: platform,
          platformAdapter: adapter,
        );

        await service.startReading();

        // Send corrupt bytes
        final statusFuture = service.onStatusChanged.first;
        adapter.tagCallback!(Uint8List.fromList([0x00, 0x01]));

        final newStatus = await statusFuture;
        expect(newStatus, NfcOperationStatus.invalidPayload);

        await service.dispose();
      },
    );
  });
}
