import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/utils/crc32.dart';

/// Compact binary wire beacon for wireless peer discovery.
///
/// Encodes device presence claims in a standardized compact layout:
/// - Magic (2B): `0x53 0x53` ("SS")
/// - Protocol Version (1B): `0x01`
/// - Device ID (16B): 128-bit public routing identifier
/// - Port (2B): TCP port for future connection (Big-Endian)
/// - Transports (1B): Bitmask of supported transports (0x01=LAN, 0x02=BLE, 0x04=Wi-Fi Direct)
/// - Name Length (1B): Length of UTF-8 display name (max 32 bytes)
/// - Display Name (0-32B): Sanitized UTF-8 bytes
/// - Checksum (4B): IEEE 802.3 CRC32 over all preceding bytes
///
/// Total size: 27 to 59 bytes. Fits comfortably within BLE advertisement limits (31B legacy, or extended advertising)
/// and UDP multicast frames.
class DiscoveryBeacon {
  static const int magicByte1 = 0x53; // 'S'
  static const int magicByte2 = 0x53; // 'S'
  static const int minHeaderSize =
      22; // Magic(2) + Ver(1) + Id(16) + Port(2) + Transports(1)
  static const int maxDisplayNameBytes = 32;

  /// Longest name a Bluetooth beacon can carry: its second half must fit
  /// one scan response (27 bytes), so the beacon is at most 47 bytes. The
  /// full name arrives in the handshake.
  static const int maxBleDisplayNameBytes = 20;

  final Uint8List deviceId;
  final int port;
  final Set<TransportType> supportedTransports;
  final String displayName;
  final int protocolVersion;

  /// This phone is hosting files for nearby phones (Host & Client). Sent as
  /// bit 0x80 of the transports byte, which older builds ignore.
  final bool hosting;

  static const int _hostingBit = 0x80;

  /// The share needs a PIN (Host & Client, private). Bit 0x40, which older
  /// builds ignore; meaningful only with [hosting].
  final bool hostingPrivate;

  static const int _privateBit = 0x40;

  /// This phone relays connections for nearby phones (mesh). Bit 0x08,
  /// which older builds ignore.
  final bool relaying;

  static const int _relayBit = 0x08;

  DiscoveryBeacon({
    required this.deviceId,
    required this.port,
    required this.supportedTransports,
    required String displayName,
    this.protocolVersion = AppConstants.protocolVersion,
    this.hosting = false,
    this.hostingPrivate = false,
    this.relaying = false,
  }) : displayName = _sanitizeDisplayName(displayName) {
    if (deviceId.length != 16) {
      throw ArgumentError.value(
        deviceId.length,
        'deviceId',
        'Device ID must be exactly 16 bytes',
      );
    }
    if (port <= 0 || port > 65535) {
      throw ArgumentError.value(
        port,
        'port',
        'Port must be between 1 and 65535',
      );
    }
  }

  /// Formats the 16-byte device ID as a 32-character hex string.
  String get deviceIdHex =>
      deviceId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Encodes this beacon to binary wire format with IEEE 802.3 CRC32 checksum.
  /// [maxNameBytes] shortens the name (on a character boundary) where the
  /// medium is small: [maxBleDisplayNameBytes] for Bluetooth.
  Uint8List toBytes({int maxNameBytes = maxDisplayNameBytes}) {
    final clampedNameBytes = _utf8Prefix(
      displayName,
      min(maxNameBytes, maxDisplayNameBytes),
    );

    final bodyLength =
        minHeaderSize + 1 + clampedNameBytes.length; // +1 for name length byte
    final totalLength = bodyLength + 4; // +4 for CRC32
    final buffer = Uint8List(totalLength);
    final byteData = ByteData.sublistView(buffer);

    // 1. Magic bytes
    buffer[0] = magicByte1;
    buffer[1] = magicByte2;

    // 2. Protocol version
    buffer[2] = protocolVersion;

    // 3. Device ID (16B)
    buffer.setRange(3, 19, deviceId);

    // 4. Port (2B big-endian)
    byteData.setUint16(19, port, Endian.big);

    // 5. Transports bitmask (1B)
    buffer[21] =
        _transportsToBitmask(supportedTransports) |
        (hosting ? _hostingBit : 0) |
        (hosting && hostingPrivate ? _privateBit : 0) |
        (relaying ? _relayBit : 0);

    // 6. Display name length (1B)
    buffer[22] = clampedNameBytes.length;

    // 7. Display name bytes
    if (clampedNameBytes.isNotEmpty) {
      buffer.setRange(23, 23 + clampedNameBytes.length, clampedNameBytes);
    }

    // 8. CRC32 checksum over preceding bytes
    final crc = Crc32.compute(buffer.sublist(0, bodyLength));
    byteData.setUint32(bodyLength, crc, Endian.big);

    return buffer;
  }

  /// Deserializes a binary beacon defensively.
  ///
  /// Rejects truncated, malformed, or corrupt packets.
  factory DiscoveryBeacon.fromBytes(Uint8List bytes) {
    if (bytes.length < minHeaderSize + 1 + 4) {
      // 27 bytes minimum (empty display name)
      throw const FormatException('Discovery beacon buffer is too short');
    }

    // 1. Validate magic bytes
    if (bytes[0] != magicByte1 || bytes[1] != magicByte2) {
      throw const FormatException('Invalid discovery beacon magic bytes');
    }

    // 2. Validate protocol version
    final version = bytes[2];
    if (version != AppConstants.protocolVersion) {
      throw FormatException('Unsupported protocol version: $version');
    }

    // 3. Extract device ID
    final deviceId = Uint8List.fromList(bytes.sublist(3, 19));

    // 4. Extract port
    final byteData = ByteData.sublistView(bytes);
    final port = byteData.getUint16(19, Endian.big);
    if (port <= 0 || port > 65535) {
      throw FormatException('Invalid port in beacon: $port');
    }

    // 5. Extract transports bitmask
    final transports = _bitmaskToTransports(bytes[21]);
    final hosting = (bytes[21] & _hostingBit) != 0;
    final hostingPrivate = hosting && (bytes[21] & _privateBit) != 0;
    final relaying = (bytes[21] & _relayBit) != 0;

    // 6. Extract display name
    final nameLength = bytes[22];
    if (nameLength > maxDisplayNameBytes) {
      throw FormatException(
        'Display name length $nameLength exceeds maximum $maxDisplayNameBytes',
      );
    }

    final expectedTotalLength = minHeaderSize + 1 + nameLength + 4;
    if (bytes.length < expectedTotalLength) {
      throw FormatException(
        'Truncated beacon: expected $expectedTotalLength bytes, got ${bytes.length}',
      );
    }

    final rawNameBytes = bytes.sublist(23, 23 + nameLength);
    final displayName = utf8.decode(rawNameBytes, allowMalformed: true);

    // 7. Validate CRC32 checksum
    final bodyLength = minHeaderSize + 1 + nameLength;
    final expectedCrc = byteData.getUint32(bodyLength, Endian.big);
    final computedCrc = Crc32.compute(bytes.sublist(0, bodyLength));

    if (computedCrc != expectedCrc) {
      throw FormatException(
        'Beacon CRC32 mismatch: computed 0x${computedCrc.toRadixString(16)}, got 0x${expectedCrc.toRadixString(16)}',
      );
    }

    return DiscoveryBeacon(
      deviceId: deviceId,
      port: port,
      supportedTransports: transports,
      displayName: displayName,
      protocolVersion: version,
      hosting: hosting,
      hostingPrivate: hostingPrivate,
      relaying: relaying,
    );
  }

  static int _transportsToBitmask(Set<TransportType> transports) {
    int mask = 0;
    if (transports.contains(TransportType.lan)) mask |= 0x01;
    if (transports.contains(TransportType.ble)) mask |= 0x02;
    if (transports.contains(TransportType.wifiDirect)) mask |= 0x04;
    return mask;
  }

  static Set<TransportType> _bitmaskToTransports(int mask) {
    final transports = <TransportType>{};
    if ((mask & 0x01) != 0) transports.add(TransportType.lan);
    if ((mask & 0x02) != 0) transports.add(TransportType.ble);
    if ((mask & 0x04) != 0) transports.add(TransportType.wifiDirect);
    return transports;
  }

  /// UTF-8 bytes of [text], cut to at most [limit] bytes without splitting
  /// a character (a split character made the beacon undecodable).
  static List<int> _utf8Prefix(String text, int limit) {
    final out = <int>[];
    for (final rune in text.runes) {
      final bytes = utf8.encode(String.fromCharCode(rune));
      if (out.length + bytes.length > limit) break;
      out.addAll(bytes);
    }
    return out;
  }

  static String _sanitizeDisplayName(String name) {
    // Strip control characters and sanitize
    final sanitized = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    if (sanitized.isEmpty) {
      return 'Vayu-Device';
    }
    return sanitized;
  }
}
