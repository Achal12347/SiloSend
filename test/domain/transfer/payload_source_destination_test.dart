import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/domain/transfer/payload_destination.dart';
import 'package:vayu/domain/transfer/payload_source.dart';

void main() {
  group('Phase 7 PayloadSource & PayloadDestination Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('vayu_test_payload_');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    group('Memory Sources and Destinations', () {
      test('MemoryPayloadSource reads slices and stream correctly', () async {
        final rawData = Uint8List.fromList(List.generate(1024, (i) => i % 256));
        final source = MemoryPayloadSource(rawData);

        expect(source.length, equals(1024));

        final slice1 = await source.readChunk(0, 512);
        expect(slice1.length, equals(512));
        expect(slice1[0], equals(0));
        expect(slice1[511], equals(511 % 256));

        final slice2 = await source.readChunk(512, 1000);
        expect(slice2.length, equals(512)); // Clamped to remaining length

        expect(() => source.readChunk(-1, 10), throwsRangeError);
        expect(() => source.readChunk(2000, 10), throwsRangeError);

        final sha = await source.computeSha256();
        expect(sha.length, equals(64));
      });

      test('MemoryPayloadDestination writes and finalizes buffer', () async {
        final dest = MemoryPayloadDestination(totalBytes: 100);
        await dest.writeChunk(0, Uint8List.fromList([1, 2, 3]));
        await dest.writeChunk(50, Uint8List.fromList([4, 5, 6]));

        expect(dest.buffer[0], equals(1));
        expect(dest.buffer[1], equals(2));
        expect(dest.buffer[2], equals(3));
        expect(dest.buffer[50], equals(4));
        expect(dest.buffer[51], equals(5));
        expect(dest.buffer[52], equals(6));

        await dest.finalize();

        // Write after finalize throws
        expect(
          () => dest.writeChunk(10, Uint8List.fromList([9])),
          throwsA(isA<TransferStorageException>()),
        );
      });

      test('MemoryPayloadDestination aborts and wipes buffer', () async {
        final dest = MemoryPayloadDestination(totalBytes: 50);
        await dest.writeChunk(0, Uint8List.fromList([10, 20, 30]));
        await dest.abortAndCleanup();

        expect(() => dest.buffer, throwsA(isA<TransferStorageException>()));
      });
    });

    group('File Sources and Destinations', () {
      test(
        'FilePayloadSource reads chunks without full-file-loading',
        () async {
          final file = File('${tempDir.path}/source_file.bin');
          final data = Uint8List.fromList(
            List.generate(200 * 1024, (i) => i % 251),
          );
          file.writeAsBytesSync(data);

          final source = FilePayloadSource(file);
          expect(source.length, equals(data.length));

          final chunk1 = await source.readChunk(0, 64 * 1024);
          expect(chunk1.length, equals(64 * 1024));
          expect(chunk1, equals(data.sublist(0, 64 * 1024)));

          final chunk2 = await source.readChunk(64 * 1024, 64 * 1024);
          expect(chunk2.length, equals(64 * 1024));
          expect(chunk2, equals(data.sublist(64 * 1024, 128 * 1024)));

          final fileSha = await source.computeSha256();
          expect(fileSha.length, equals(64));

          await source.close();
        },
      );

      test('FilePayloadDestination writes out-of-order chunks, verifies, and atomically promotes', () async {
        final targetPath = '${tempDir.path}/final_output.bin';
        final totalBytes = 150 * 1024;
        final rawData = Uint8List.fromList(
          List.generate(totalBytes, (i) => (i * 3) % 256),
        );

        final dest = FilePayloadDestination(
          targetFilePath: targetPath,
          totalBytes: totalBytes,
        );
        final stagingFile = File('$targetPath.vayu.tmp');

        // Write out of order: chunk 1 first, then chunk 0, then chunk 2
        final chunk0 = rawData.sublist(0, 64 * 1024);
        final chunk1 = rawData.sublist(64 * 1024, 128 * 1024);
        final chunk2 = rawData.sublist(128 * 1024, totalBytes);

        await dest.writeChunk(64 * 1024, chunk1);
        await dest.writeChunk(0, chunk0);
        await dest.writeChunk(128 * 1024, chunk2);

        expect(stagingFile.existsSync(), isTrue);
        expect(File(targetPath).existsSync(), isFalse);

        // Compute SHA-256 over staging file
        final stagingSha = await dest.computeSha256();

        // Memory source hash for comparison
        final memSource = MemoryPayloadSource(rawData);
        final expectedSha = await memSource.computeSha256();
        expect(stagingSha, equals(expectedSha));

        // Finalize (promotes to final destination)
        await dest.finalize();

        expect(File(targetPath).existsSync(), isTrue);
        expect(stagingFile.existsSync(), isFalse);
        expect(File(targetPath).readAsBytesSync(), equals(rawData));
      });

      test('FilePayloadDestination deletes staging file on abort', () async {
        final targetPath = '${tempDir.path}/aborted.bin';
        final dest = FilePayloadDestination(
          targetFilePath: targetPath,
          totalBytes: 100,
        );
        final stagingFile = File('$targetPath.vayu.tmp');

        await dest.writeChunk(0, Uint8List.fromList([1, 2, 3, 4]));
        expect(stagingFile.existsSync(), isTrue);

        await dest.abortAndCleanup();
        expect(stagingFile.existsSync(), isFalse);
        expect(File(targetPath).existsSync(), isFalse);
      });
    });

    group('Streaming verification hash', () {
      // Above FilePayloadDestination.streamingHashMinBytes.
      final size = FilePayloadDestination.streamingHashMinBytes + 123457;
      final data = Uint8List.fromList(
        List<int>.generate(size, (i) => (i * 31 + 7) & 0xff),
      );
      final expected = crypto.sha256.convert(data).toString();
      const chunk = 256 * 1024;

      test('in-order writes are hashed while they arrive', () async {
        final dest = FilePayloadDestination(
          targetFilePath: '${tempDir.path}/streamed.bin',
          totalBytes: size,
        );
        for (var offset = 0; offset < size; offset += chunk) {
          final end = offset + chunk > size ? size : offset + chunk;
          await dest.writeChunk(
            offset,
            Uint8List.sublistView(data, offset, end),
          );
        }
        expect(await dest.computeSha256(), expected);
        await dest.finalize();
      });

      test('out-of-order writes fall back to hashing the file', () async {
        final dest = FilePayloadDestination(
          targetFilePath: '${tempDir.path}/reordered.bin',
          totalBytes: size,
        );
        final offsets = [
          for (var offset = 0; offset < size; offset += chunk) offset,
        ];
        // Swap two chunks, as a retransmit after a timeout would.
        final tmp = offsets[3];
        offsets[3] = offsets[4];
        offsets[4] = tmp;
        for (final offset in offsets) {
          final end = offset + chunk > size ? size : offset + chunk;
          await dest.writeChunk(
            offset,
            Uint8List.sublistView(data, offset, end),
          );
        }
        expect(await dest.computeSha256(), expected);
        await dest.finalize();
      });

      test('a corrupted chunk is still detected', () async {
        final dest = FilePayloadDestination(
          targetFilePath: '${tempDir.path}/corrupt.bin',
          totalBytes: size,
        );
        for (var offset = 0; offset < size; offset += chunk) {
          final end = offset + chunk > size ? size : offset + chunk;
          final piece = Uint8List.fromList(data.sublist(offset, end));
          if (offset == chunk * 2) piece[10] ^= 0x01;
          await dest.writeChunk(offset, piece);
        }
        expect(await dest.computeSha256(), isNot(expected));
        await dest.abortAndCleanup();
      });

      test('abort mid-stream cleans up', () async {
        final dest = FilePayloadDestination(
          targetFilePath: '${tempDir.path}/aborted.bin',
          totalBytes: size,
        );
        await dest.writeChunk(0, Uint8List.sublistView(data, 0, chunk));
        await dest.abortAndCleanup();
        expect(File(dest.stagingPath).existsSync(), isFalse);
      });
    });

    group('Saving never destroys other files', () {
      test(
        'an existing file at the target is kept; the new one gets (1)',
        () async {
          final target = '${tempDir.path}/report.pdf';
          File(target).writeAsStringSync('old');
          final dest = FilePayloadDestination(
            targetFilePath: target,
            totalBytes: 3,
          );
          await dest.writeChunk(0, Uint8List.fromList([1, 2, 3]));
          await dest.finalize();

          expect(File(target).readAsStringSync(), 'old');
          expect(dest.targetFilePath, '${tempDir.path}/report (1).pdf');
          expect(File(dest.targetFilePath).readAsBytesSync(), [1, 2, 3]);
          expect(File(dest.stagingPath).existsSync(), isFalse);
          await dest.close();
        },
      );

      test('a vanished staging file is an error, never a success', () async {
        final dest = FilePayloadDestination(
          targetFilePath: '${tempDir.path}/gone.bin',
          totalBytes: 2,
        );
        await dest.writeChunk(0, Uint8List.fromList([7, 8]));
        await dest.computeSha256(); // closes the staging file
        File(dest.stagingPath).deleteSync();

        await expectLater(
          dest.finalize(),
          throwsA(isA<TransferStorageException>()),
        );
        expect(File('${tempDir.path}/gone.bin').existsSync(), isFalse);
      });

      test('duplicate names are numbered before the extension', () {
        expect(numberedPath('/d/a.b/photo.jpg', 0), '/d/a.b/photo.jpg');
        expect(numberedPath('/d/a.b/photo.jpg', 2), '/d/a.b/photo (2).jpg');
        expect(numberedPath(r'C:\d\README', 1), r'C:\d\README (1)');
        expect(numberedPath('/d/.hidden', 1), '/d/.hidden (1)');
      });
    });

    test('a large in-order receive is hashed while it arrives, with bounded backlog', () async {
      // 40 MiB in 1 MiB writes: more than the hashing backlog limit, so
      // writes must wait for the worker instead of queueing everything.
      const chunk = 1024 * 1024;
      const total = 40 * chunk;
      final data = Uint8List(total);
      for (var i = 0; i < total; i++) {
        data[i] = (i * 31) & 0xFF;
      }
      final dest = FilePayloadDestination(
        targetFilePath: '${tempDir.path}/large.bin',
        totalBytes: total,
      );
      for (var offset = 0; offset < total; offset += chunk) {
        await dest.writeChunk(
          offset,
          Uint8List.sublistView(data, offset, offset + chunk),
        );
      }
      expect(
        await dest.computeSha256(),
        crypto.sha256.convert(data).toString(),
      );
      await dest.finalize();
      await dest.close();
    });
  });
}
