import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/chat/chat_store.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/chats/conversation_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/motion.dart';

void main() {
  late AppContainer app;

  Future<void> pump(WidgetTester tester, {bool noMotion = false}) async {
    await tester.runAsync(() async {
      app = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity.generate(displayName: 'Me', platform: 'android'),
        ),
        chatStorage: InMemoryChatStorage([
          Conversation(
            peerDeviceId: 'ab' * 16,
            peerName: 'Ana',
            accepted: true,
            messages: [
              ChatMessage(
                id: 'cd' * 16,
                fromMe: false,
                text: 'already here',
                sentAt: DateTime(2026, 10, 19),
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
          data: MediaQuery.of(context).copyWith(disableAnimations: noMotion),
          child: child!,
        ),
        home: ConversationPage(
          container: app,
          peerDeviceId: 'ab' * 16,
          peerName: 'Ana',
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> sendWhileOpen(WidgetTester tester) async {
    // Ana is not reachable: the message stays here as failed, which is
    // enough to see it appear.
    await tester.runAsync(() async {
      try {
        await app.chatService.send(
          deviceId: 'ab' * 16,
          peerName: 'Ana',
          text: 'new one',
        );
      } catch (_) {}
    });
    await tester.pump();
  }

  testWidgets('messages already in the chat do not animate; a new one eases '
      'in once, then settles', (tester) async {
    await pump(tester);
    expect(find.text('already here'), findsOneWidget);
    expect(find.byType(EaseIn), findsNothing);

    await sendWhileOpen(tester);
    expect(find.text('new one'), findsOneWidget);
    expect(find.byType(EaseIn), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_opacityOfNew(tester), 1.0);
  });

  testWidgets('with "Remove animations" nothing moves', (tester) async {
    await pump(tester, noMotion: true);
    await sendWhileOpen(tester);
    // No animation: fully visible on the first frame it is shown.
    expect(_opacityOfNew(tester), 1.0);
    expect(find.text('new one'), findsOneWidget);
  });
}

double _opacityOfNew(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(of: find.byType(EaseIn), matching: find.byType(Opacity)),
    )
    .opacity;
