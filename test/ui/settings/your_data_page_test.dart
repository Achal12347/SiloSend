import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/chat/chat_store.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/resumable_transfers.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/settings/your_data_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

void main() {
  test(
    'unfinished downloads: deleting removes the files and the list',
    () async {
      final dir = Directory.systemTemp.createTempSync('vayu_data_');
      try {
        final file = File(
          '${dir.path}/a.bin${ResumableTransfers.stagingSuffix}',
        )..writeAsBytesSync(List.filled(500, 1));
        final r = ResumableTransfers();
        r.keep(
          'k',
          PartialTransfer(
            stagingPath: file.path,
            contiguousChunks: 1,
            contiguousBytes: 500,
          ),
        );
        expect(r.keptBytes, 500);
        await r.discardAll();
        expect(r.keptPaths, isEmpty);
        expect(file.existsSync(), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );

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
          chatStorage: InMemoryChatStorage([
            Conversation(
              peerDeviceId: 'ab' * 16,
              peerName: 'Ana',
              accepted: true,
              messages: [
                for (var i = 0; i < 3; i++)
                  ChatMessage(
                    id: '${'0' * 31}$i',
                    fromMe: i.isEven,
                    text: 'm$i',
                    sentAt: DateTime(2026, 10, 19, 10, i),
                    state: MessageState.read,
                  ),
              ],
            ),
          ]),
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
          home: YourDataPage(container: app),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('shows real counts; deleting chats asks first', (tester) async {
      await pump(tester);
      expect(
        find.textContaining('1 conversation · 3 messages'),
        findsOneWidget,
      );
      expect(find.textContaining('None\nKept 30 minutes'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete Chats'));
      await tester.pumpAndSettle();
      expect(find.text('Delete all chats?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(app.chatService.chats, isEmpty);
      expect(
        find.textContaining('0 conversations · 0 messages'),
        findsOneWidget,
      );
    });

    testWidgets('at 2x text nothing overflows', (tester) async {
      await pump(tester, textScale: 2);
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
    });
  });
}
