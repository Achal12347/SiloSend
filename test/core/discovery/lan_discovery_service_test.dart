import 'package:flutter_test/flutter_test.dart';

import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/discovery/lan_discovery_service.dart';

void main() {
  group('LanDiscoveryService Tests', () {
    const localId = '11111111222233334444555566667777';

    test('initializes with transportType lan and inactive status', () {
      final service = LanDiscoveryService(localDeviceId: localId);
      expect(service.transportType, equals(TransportType.lan));
      expect(service.isScanning, isFalse);
      expect(service.isAdvertising, isFalse);
      service.dispose();
    });

    test('starts and stops discovery safely', () async {
      final service = LanDiscoveryService(localDeviceId: localId);

      await service.startDiscovery();
      expect(service.isScanning, isTrue);

      await service.stopDiscovery();
      expect(service.isScanning, isFalse);

      service.dispose();
    });
  });
}
