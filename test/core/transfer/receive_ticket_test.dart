import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/transfer/receive_ticket.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';

const _ticket = '00112233445566778899aabbccddeeff';
const _sender = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _batch = '0123456789abcdef0123456789abcdef';

void main() {
  String proof({
    String ticket = _ticket,
    String sender = _sender,
    String batch = _batch,
  }) => ReceiveTicket.proof(
    ticketHex: ticket,
    senderDeviceId: sender,
    batchId: batch,
  );

  bool verify(String p, {String sender = _sender, String batch = _batch}) =>
      ReceiveTicket.verify(
        ticketHex: _ticket,
        senderDeviceId: sender,
        batchId: batch,
        proofHex: p,
      );

  test('a proof made with the ticket verifies', () {
    expect(verify(proof()), isTrue);
    expect(verify(proof().toUpperCase()), isTrue);
  });

  test('a proof is bound to the ticket, the sender and the batch', () {
    expect(verify(proof(ticket: 'ff' * 16)), isFalse);
    expect(verify(proof(), sender: 'bb' * 16), isFalse);
    expect(verify(proof(), batch: 'cd' * 16), isFalse);
    expect(verify('00' * 32), isFalse);
    expect(verify('short'), isFalse);
  });

  test('the proof travels in the batch offer and older offers have none', () {
    final offer = TransferBatchOfferPayload(
      batchId: Uint8List(16),
      files: [BatchManifestEntry(fileName: 'a', sizeBytes: 1, mimeType: 'x')],
      receiveProof: proof(),
    );
    expect(
      TransferBatchOfferPayload.fromBytes(offer.toBytes()).receiveProof,
      proof(),
    );
    final plain = TransferBatchOfferPayload(
      batchId: Uint8List(16),
      files: [BatchManifestEntry(fileName: 'a', sizeBytes: 1, mimeType: 'x')],
    );
    expect(
      TransferBatchOfferPayload.fromBytes(plain.toBytes()).receiveProof,
      isNull,
    );
  });
}
