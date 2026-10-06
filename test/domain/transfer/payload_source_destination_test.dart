import 'dart:io';
import 'dart:typed_data';

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
  });
}
