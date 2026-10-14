import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/transfer/consent_registry.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

const _sender = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _other = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _batch = '0123456789abcdef0123456789abcdef';

final _entries = [
  BatchManifestEntry(fileName: 'a.jpg', sizeBytes: 100, mimeType: 'image/jpeg'),
  BatchManifestEntry(
    fileName: 'b.pdf',
    sizeBytes: 200,
    mimeType: 'application/pdf',
  ),
];

void main() {
  late DateTime now;
  late ConsentRegistry registry;

  setUp(() {
    now = DateTime(2026, 10, 14, 12);
    registry = ConsentRegistry(clock: () => now);
    registry.grant(senderDeviceId: _sender, batchId: _batch, entries: _entries);
  });

  bool claim({
    String sender = _sender,
    String batch = _batch,
    int index = 0,
    String name = 'a.jpg',
    int size = 100,
    String mime = 'image/jpeg',
  }) => registry.claim(
    senderDeviceId: sender,
    batchId: batch,
    index: index,
    fileName: name,
    sizeBytes: size,
    mimeType: mime,
  );

  test('a matching file from the granted sender is authorized', () {
    expect(claim(), isTrue);
  });

  test('another sender cannot use the grant', () {
    expect(claim(sender: _other), isFalse);
  });

  test('another batch ID is not covered', () {
    expect(claim(batch: 'ffffffffffffffffffffffffffffffff'), isFalse);
  });

  test('a changed name, size or type is not covered', () {
    expect(claim(name: 'evil.apk'), isFalse);
    expect(claim(size: 101), isFalse);
    expect(claim(mime: 'application/octet-stream'), isFalse);
    expect(claim(index: 1), isFalse); // b.pdf's entry, a.jpg's details
    expect(claim(index: 7), isFalse);
  });

  test('an entry cannot be claimed twice at once or after completion', () {
    expect(claim(), isTrue);
    expect(claim(), isFalse);
    registry.settle(
      senderDeviceId: _sender,
      batchId: _batch,
      index: 0,
      completed: true,
    );
    expect(claim(), isFalse);
  });

  test('a failed file frees its entry for a retry', () {
    expect(claim(), isTrue);
    registry.settle(
      senderDeviceId: _sender,
      batchId: _batch,
      index: 0,
      completed: false,
    );
    expect(claim(), isTrue);
  });

  test('the grant expires after the idle lifetime', () {
    now = now.add(const Duration(minutes: 11));
    expect(claim(), isFalse);
  });

  test('activity keeps the grant alive', () {
    now = now.add(const Duration(minutes: 9));
    expect(claim(), isTrue);
    registry.settle(
      senderDeviceId: _sender,
      batchId: _batch,
      index: 0,
      completed: true,
    );
    now = now.add(const Duration(minutes: 9));
    expect(
      claim(index: 1, name: 'b.pdf', size: 200, mime: 'application/pdf'),
      isTrue,
    );
  });

  test('the grant is removed once every file completed', () {
    for (final i in [0, 1]) {
      final e = _entries[i];
      expect(
        claim(index: i, name: e.fileName, size: e.sizeBytes, mime: e.mimeType),
        isTrue,
      );
      registry.settle(
        senderDeviceId: _sender,
        batchId: _batch,
        index: i,
        completed: true,
      );
    }
    expect(registry.hasGrant(_sender, _batch), isFalse);
  });

  test('revoking a sender removes its grants', () {
    registry.revokeSender(_sender);
    expect(claim(), isFalse);
  });

  group('wire format', () {
    test('batch offer round-trips and sanitizes names', () {
      final offer = TransferBatchOfferPayload(
        batchId: Uint8List(16)..[0] = 7,
        files: [
          BatchManifestEntry(
            fileName: '../../etc/passwd',
            sizeBytes: 5,
            mimeType: 'text/plain',
          ),
          ..._entries,
        ],
      );
      final back = TransferBatchOfferPayload.fromBytes(offer.toBytes());
      expect(back.batchIdHex, offer.batchIdHex);
      expect(back.files, hasLength(3));
      expect(back.files.first.fileName, isNot(contains('/')));
      expect(back.totalBytes, 305);
    });

    test('malformed offers are rejected', () {
      expect(
        () => TransferBatchOfferPayload.fromBytes(Uint8List(10)),
        throwsFormatException,
      );
      expect(
        () => TransferBatchOfferPayload.fromBytes(
          Uint8List.fromList([...Uint8List(16), ...'{"files":[]}'.codeUnits]),
        ),
        throwsFormatException,
      );
      expect(
        () => TransferBatchOfferPayload.fromBytes(
          Uint8List.fromList([...Uint8List(16), ...'not json'.codeUnits]),
        ),
        throwsFormatException,
      );
    });

    test('batch response round-trips with its reason', () {
      final response = TransferBatchResponsePayload(
        batchId: Uint8List(16),
        accepted: false,
        reason: TransferCancelReason.storageFull,
        message: 'Not enough storage space',
      );
      final back = TransferBatchResponsePayload.fromBytes(response.toBytes());
      expect(back.accepted, isFalse);
      expect(back.reason, TransferCancelReason.storageFull);
      expect(back.message, 'Not enough storage space');
    });

    test('file markers decode only well-formed tags', () {
      final marker = BatchFileMarker(batchIdHex: _batch, index: 3);
      final back = BatchFileMarker.tryDecode(marker.encode())!;
      expect(back.batchIdHex, _batch);
      expect(back.index, 3);
      expect(BatchFileMarker.tryDecode(null), isNull);
      expect(
        BatchFileMarker.tryDecode(
          Uint8List.fromList('{"batch":"x","i":1}'.codeUnits),
        ),
        isNull,
      );
      expect(
        BatchFileMarker.tryDecode(Uint8List.fromList('garbage'.codeUnits)),
        isNull,
      );
    });
  });
}
