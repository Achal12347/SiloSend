import 'dart:convert';
import 'dart:typed_data';

import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// One file announced in a batch offer.
///
/// Consent is bound to name, size and type. The SHA-256 is deliberately not
/// part of it: the sender is the party being trusted, the per-file hash is
/// still verified on arrival, and leaving it out lets a sender start without
/// hashing every file first.
class BatchManifestEntry {
  final String fileName;
  final int sizeBytes;
  final String mimeType;

  BatchManifestEntry({
    required String fileName,
    required this.sizeBytes,
    required this.mimeType,
  }) : fileName = TransferMetadataPayload.sanitizeFileName(fileName) {
    if (sizeBytes < 0) {
      throw ArgumentError.value(sizeBytes, 'sizeBytes', 'Cannot be negative');
    }
  }

  Map<String, dynamic> toJson() => {
    'n': fileName,
    's': sizeBytes,
    'm': mimeType,
  };

  factory BatchManifestEntry.fromJson(Map<String, dynamic> json) {
    final name = json['n'];
    final size = json['s'];
    final mime = json['m'];
    if (name is! String || name.isEmpty || size is! int || mime is! String) {
      throw const FormatException('Invalid batch manifest entry');
    }
    return BatchManifestEntry(fileName: name, sizeBytes: size, mimeType: mime);
  }

  /// True when an incoming file offer matches this entry exactly.
  bool matches({
    required String fileName,
    required int sizeBytes,
    required String mimeType,
  }) =>
      this.fileName == fileName &&
      this.sizeBytes == sizeBytes &&
      this.mimeType == mimeType;
}

/// Packet 0x15: the sender announces every file of a batch so the receiver
/// can approve all of them with one decision.
class TransferBatchOfferPayload {
  static const int maxFiles = 1000;

  final Uint8List batchId;
  final List<BatchManifestEntry> files;

  /// Proof that the sender holds the receiver's Receive ticket (see
  /// `ReceiveTicket`); absent for ordinary offers. Older builds ignore it.
  final String? receiveProof;

  TransferBatchOfferPayload({
    required this.batchId,
    required this.files,
    this.receiveProof,
  }) {
    if (batchId.length != 16) {
      throw ArgumentError('batchId must be 16 bytes');
    }
    if (files.isEmpty || files.length > maxFiles) {
      throw ArgumentError('A batch holds 1 to $maxFiles files');
    }
  }

  String get batchIdHex => _hex(batchId);

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  Uint8List toBytes() {
    final body = utf8.encode(
      jsonEncode({
        'files': files.map((f) => f.toJson()).toList(),
        if (receiveProof != null) 'proof': receiveProof,
      }),
    );
    return Uint8List.fromList([...batchId, ...body]);
  }

  factory TransferBatchOfferPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 17) {
      throw const FormatException('Batch offer too short');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes.sublist(16)));
    } catch (_) {
      throw const FormatException('Batch offer body is not valid JSON');
    }
    if (json is! Map<String, dynamic> || json['files'] is! List) {
      throw const FormatException('Batch offer has no file list');
    }
    final list = json['files'] as List;
    if (list.isEmpty || list.length > maxFiles) {
      throw const FormatException('Batch offer file count out of range');
    }
    final proof = json['proof'];
    return TransferBatchOfferPayload(
      batchId: Uint8List.fromList(bytes.sublist(0, 16)),
      receiveProof: proof is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(proof)
          ? proof
          : null,
      files: [
        for (final item in list)
          if (item is Map<String, dynamic>)
            BatchManifestEntry.fromJson(item)
          else
            throw const FormatException('Invalid batch manifest entry'),
      ],
    );
  }
}

/// Packet 0x16: the receiver's single answer to a batch offer.
class TransferBatchResponsePayload {
  static const int maxMessageLength = 256;

  final Uint8List batchId;
  final bool accepted;

  /// Why the batch was refused (`null` when accepted).
  final TransferCancelReason? reason;
  final String message;

  TransferBatchResponsePayload({
    required this.batchId,
    required this.accepted,
    this.reason,
    this.message = '',
  }) {
    if (batchId.length != 16) {
      throw ArgumentError('batchId must be 16 bytes');
    }
  }

  String get batchIdHex => _hex(batchId);

  Uint8List toBytes() {
    var msg = utf8.encode(message);
    if (msg.length > maxMessageLength) msg = msg.sublist(0, maxMessageLength);
    return Uint8List.fromList([
      ...batchId,
      accepted ? 1 : 0,
      reason?.code ?? 0,
      ...msg,
    ]);
  }

  factory TransferBatchResponsePayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 18) {
      throw const FormatException('Batch response too short');
    }
    final code = bytes[17];
    TransferCancelReason? reason;
    if (code != 0) {
      try {
        reason = TransferCancelReason.fromCode(code);
      } on FormatException {
        reason = TransferCancelReason.declined;
      }
    }
    return TransferBatchResponsePayload(
      batchId: Uint8List.fromList(bytes.sublist(0, 16)),
      accepted: bytes[16] == 1,
      reason: reason,
      message: utf8.decode(bytes.sublist(18), allowMalformed: true),
    );
  }
}

/// Tag carried in each file's metadata `extraMetadata`, linking the file to
/// its batch offer. It only names the batch; whether the file is accepted is
/// decided by the receiver's own consent record, never by this tag.
class BatchFileMarker {
  final String batchIdHex;
  final int index;

  const BatchFileMarker({required this.batchIdHex, required this.index});

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(jsonEncode({'batch': batchIdHex, 'i': index})),
  );

  static BatchFileMarker? tryDecode(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) return null;
      final id = json['batch'];
      final index = json['i'];
      if (id is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
          index is! int ||
          index < 0) {
        return null;
      }
      return BatchFileMarker(batchIdHex: id, index: index);
    } catch (_) {
      return null;
    }
  }
}
