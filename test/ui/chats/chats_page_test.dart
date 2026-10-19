import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/chat/chat_store.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/chats/chats_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

// Conversations below exist only in this test (generic names).
Conversation _conversation({
  required String peer,
  required String name,
  required bool accepted,
  required String text,
}) => Conversation(
  peerDeviceId: peer,
  peerName: name,
  accepted: accepted,
  messages: [
    ChatMessage(
      id: peer.substring(0, 32),
      fromMe: false,
      text: text,
      sentAt: DateTime.now(),
      state: MessageState.delivered,
    ),
  ],
);

void main() {
  late AppContainer container;

  Future<void> pump(WidgetTester tester, List<Conversation> saved) async {
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 8)),
            displayName: 'Tester',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
        chatStorage: InMemoryChatStorage(saved),
      );
      await container.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        home: AppScope(container: container, child: const ChatsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() => container.dispose());

  testWidgets('no chats: an honest empty state and New chat', (tester) async {
    await pump(tester, const []);
    expect(find.text('No chats yet'), findsOneWidget);
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('Message requests'), findsNothing);
  });

  testWidgets('a request shows as a link, not in the chat list', (
    tester,
  ) async {
    await pump(tester, [
      _conversation(
        peer: 'a1' * 16,
        name: 'Phone A',
        accepted: false,
        text: 'Hi there',
      ),
      _conversation(
        peer: 'b2' * 16,
        name: 'Phone B',
        accepted: true,
        text: 'See you',
      ),
    ]);
    expect(find.text('Message requests'), findsOneWidget);
    expect(find.text('Phone A sent you a message'), findsOneWidget);
    // Only the accepted conversation is in the list.
    expect(find.text('Phone B'), findsOneWidget);
    expect(find.text('Hi there'), findsNothing);
  });

  testWidgets('opening a request makes it a chat', (tester) async {
    await pump(tester, [
      _conversation(
        peer: 'a1' * 16,
        name: 'Phone A',
        accepted: false,
        text: 'Hi there',
      ),
    ]);
    await tester.tap(find.text('Message requests'));
    await tester.pumpAndSettle();
    expect(find.text('Hi there'), findsOneWidget);
    await tester.tap(find.text('Phone A'));
    await tester.pumpAndSettle();
    // The conversation is open and accepted.
    expect(find.text('Hi there'), findsOneWidget);
    expect(container.chatService.requests, isEmpty);
    expect(container.chatService.chats.single.unread, 0);
  });
}
