@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/chat/chat_store.dart';
import 'package:vayu/core/contacts/received_cards.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/pairing/nfc_pairing_service.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/permission_report.dart' hide SettingsPage;
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';
import 'package:vayu/main.dart';
import 'package:vayu/platform/platform_service.dart';
import 'package:vayu/ui/apps/apps_games_page.dart';
import 'package:vayu/ui/card/incoming_card_watcher.dart';
import 'package:vayu/ui/contacts/contact_sharing_page.dart';
import 'package:vayu/ui/home/nearby_devices_page.dart';
import 'package:vayu/ui/card/my_card_page.dart';
import 'package:vayu/ui/card/received_cards_page.dart';
import 'package:vayu/ui/receive/receive_page.dart';
import 'package:vayu/ui/settings/permissions_page.dart';
import 'package:vayu/ui/settings/settings_page.dart';
import 'package:vayu/ui/transfer/selected_items_page.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Renders the main screens to PNG for store listings and design review.
///
/// Uses the real widgets with SAMPLE data that exists only in this test:
/// the nearby phones ("Riya's Galaxy S24", "Kabir's Pixel 8"), the cards and
/// the transfer are invented for the pictures and never appear in the app.
/// Not part of the normal test run.
///
/// Run: VAYU_SCREENSHOTS=1 flutter test test/screenshots/render_screens_test.dart
/// Output: screenshots/ (or VAYU_SCREENSHOTS_DIR).
void main() {
  final enabled = Platform.environment['VAYU_SCREENSHOTS'] != null;
  final outDir = Directory(
    Platform.environment['VAYU_SCREENSHOTS_DIR'] ?? 'screenshots',
  );

  setUpAll(() async {
    if (!enabled) return;
    outDir.createSync(recursive: true);
    await _loadFonts();
  });

  void shotTest(String name, Future<void> Function(_Shot shot) body) {
    testWidgets(name, (tester) async {
      await body(_Shot(tester, outDir));
    }, skip: !enabled);
  }

  shotTest('01 home', (s) async {
    final c = await s.app();
    s.addPeers(c);
    await s.settle();
    await s.save('01_home');
    await s.close(c);
  });

  shotTest('02 home dark', (s) async {
    final c = await s.app(theme: AppThemePreference.dark);
    s.addPeers(c);
    await s.settle();
    await s.save('02_home_dark');
    await s.close(c);
  });

  shotTest('03 send', (s) async {
    final c = await s.app();
    s.addPeers(c);
    await s.settle();
    unawaited(
      SelectedItemsPage.open(
        s.navContext,
        documents: const [
          SelectedDocument(
            identifier: 'content://sample/1',
            name: 'Trip to Ladakh.mp4',
            sizeBytes: 1524000000,
            mimeType: 'video/mp4',
          ),
          SelectedDocument(
            identifier: 'content://sample/2',
            name: 'Itinerary.pdf',
            sizeBytes: 2400000,
            mimeType: 'application/pdf',
          ),
          SelectedDocument(
            identifier: 'content://sample/3',
            name: 'Group photo.jpg',
            sizeBytes: 4800000,
            mimeType: 'image/jpeg',
          ),
        ],
        container: c,
      ),
    );
    await s.settle();
    await s.save('03a_send_review');
    await s.tester.tap(find.text('Next: choose device'));
    await s.settle();
    await s.save('03_send');
    await s.close(c);
  });

  shotTest('04 receive', (s) async {
    final c = await s.app();
    await s.settle();
    unawaited(ReceivePage.open(s.navContext, c));
    await s.settle(rounds: 12);
    await s.save('04_receive');
    await s.close(c);
  });

  shotTest('05 transfer', (s) async {
    final c = await s.app();
    await s.settle();
    final task = await s.liveTransfer(c);
    unawaited(TransferDetailPage.open(s.navContext, c, task: task));
    await s.settle();
    await s.save('05_transfer');
    await task.cancel();
    await s.close(c);
  });

  shotTest('06 card received', (s) async {
    final c = await s.app();
    await s.settle();
    unawaited(
      showIncomingCardSheet(
        s.navContext,
        container: c,
        vcard: const VayuCard(
          name: 'Riya Sen',
          title: 'Product Designer',
          company: 'Studio North',
          phone: '+91 98765 43210',
          email: 'riya@studionorth.in',
          website: 'studionorth.in',
          accent: 1,
        ).toVcard(),
      ),
    );
    await s.settle();
    await s.save('06_card_received');
    await s.close(c);
  });

  shotTest('07 my card', (s) async {
    final c = await s.app();
    await s.settle();
    unawaited(MyCardPage.open(s.navContext, c));
    await s.settle();
    await s.save('07_my_card');
    await s.close(c);
  });

  shotTest('08 received cards', (s) async {
    final c = await s.app();
    await s.settle();
    for (final card in const [
      VayuCard(
        name: 'Riya Sen',
        company: 'Studio North',
        phone: '+91 98765 43210',
        email: 'riya@studionorth.in',
        website: 'studionorth.in',
        accent: 1,
      ),
      VayuCard(name: 'Kabir Rao', company: 'Halcyon Labs', accent: 3),
      VayuCard(
        name: 'Meera Iyer',
        title: 'Architect',
        phone: '+91 99887 76655',
        email: 'meera@iyerstudio.in',
        website: 'iyerstudio.in',
        accent: 2,
      ),
      VayuCard(name: 'Dev Malhotra', title: 'Photographer', accent: 4),
      VayuCard(name: 'Ananya Das', company: 'Pearl Studio', accent: 5),
    ]) {
      await s.tester.runAsync(
        () => c.receivedCards!.addBytes(card.toVcard(), via: ReceivedVia.tap),
      );
    }
    unawaited(ReceivedCardsPage.open(s.navContext, c));
    await s.settle(rounds: 24);
    await s.save('08_received_cards');
    // Mid-scroll: the card in focus pops out.
    await s.tester.drag(find.byType(ListView).last, const Offset(0, -260));
    await s.settle();
    await s.save('08b_received_cards_scrolled');
    await s.tester.longPress(find.text('Meera Iyer').first);
    await s.settle();
    await s.save('08c_card_long_press');
    await s.close(c);
  });

  shotTest('09 permissions', (s) async {
    final c = await s.app();
    await s.settle();
    unawaited(PermissionsPage.open(s.navContext, c));
    await s.settle();
    await s.save('09_permissions');
    await s.close(c);
  });

  shotTest('10 settings', (s) async {
    final c = await s.app();
    await s.settle();
    unawaited(
      Navigator.of(s.navContext)
          .push(MaterialPageRoute(builder: (_) => SettingsPage(container: c))),
    );
    await s.settle();
    await s.save('10_settings');
    await s.close(c);
  });

  shotTest('12 nearby devices', (s) async {
    final c = await s.app();
    s.addPeers(c);
    await s.settle();
    unawaited(NearbyDevicesPage.open(s.navContext, c));
    await s.settle();
    await s.save('12_nearby');
    await s.close(c);
  });

  shotTest('13 contact sharing', (s) async {
    final c = await s.app();
    await s.settle();
    unawaited(ContactSharingPage.open(s.navContext, c));
    await s.settle();
    await s.save('13_contact_sharing');
    await s.close(c);
  });

  shotTest('14 chats tab', (s) async {
    final now = DateTime.now();
    ChatMessage msg(
      String id,
      bool me,
      String text,
      int minutesAgo,
      MessageState state,
    ) => ChatMessage(
      id: id * 16,
      fromMe: me,
      text: text,
      sentAt: now.subtract(Duration(minutes: minutesAgo)),
      state: state,
    );
    final c = await s.app(
      chats: [
        Conversation(
          peerDeviceId: 'a1' * 16,
          peerName: "Riya's Galaxy S24",
          accepted: true,
          messages: [
            msg('01', false, 'Are you near the gate?', 9, MessageState.read),
            msg(
              '02',
              true,
              'Yes, sending the photos now',
              8,
              MessageState.read,
            ),
            msg('03', false, 'Got them, thanks!', 2, MessageState.delivered),
          ],
        ),
        Conversation(
          peerDeviceId: 'b2' * 16,
          peerName: "Kabir's Pixel 8",
          accepted: false,
          messages: [
            msg(
              '04',
              false,
              'Hi, can you share the deck?',
              30,
              MessageState.delivered,
            ),
          ],
        ),
      ],
    );
    await s.settle();
    await s.tester.tap(find.text('Chats').last);
    await s.settle();
    await s.save('14_chats');
    await s.tester.tap(find.text("Riya's Galaxy S24"));
    await s.settle();
    await s.save('14b_conversation');
    await s.close(c);
  });

  shotTest('16 host and client', (s) async {
    final c = await s.app();
    await s.settle();
    await s.tester.tap(find.text('Host & Client').last);
    await s.settle();
    await s.save('16_host_idle');
    // Sample share (test only); no files are read for the picture.
    c.hostService.startHosting('Trip photos', const [
      SelectedDocument(
        identifier: 'content://sample/1',
        name: 'Beach.jpg',
        sizeBytes: 4200000,
        mimeType: 'image/jpeg',
      ),
      SelectedDocument(
        identifier: 'content://sample/2',
        name: 'Sunset.mp4',
        sizeBytes: 182000000,
        mimeType: 'video/mp4',
      ),
    ]);
    await s.settle();
    await s.save('16b_hosting');
    await s.tester.tap(find.text('Client'));
    await s.settle();
    await s.save('16c_client');
    await c.hostService.stopHosting();
    await s.close(c);
  });

  shotTest('15 apps and games', (s) async {
    final c = await s.app();
    await s.settle();
    unawaited(AppsGamesPage.open(s.navContext));
    await s.settle();
    await s.save('15_apps_games');
    await s.close(c);
  });

  shotTest('11 onboarding', (s) async {
    final c = await s.app(onboarded: false);
    await s.settle();
    await s.save('11_onboarding');
    await s.close(c);
  });
}

// ---------------------------------------------------------------- harness

class _Shot {
  final WidgetTester tester;
  final Directory outDir;
  final GlobalKey _boundary = GlobalKey();

  _Shot(this.tester, this.outDir);

  BuildContext get navContext =>
      rootNavigatorKey.currentState!.overlay!.context;

  Future<AppContainer> app({
    AppThemePreference theme = AppThemePreference.light,
    bool onboarded = true,
    List<Conversation> chats = const [],
  }) async {
    // Pixel 7-like screen: 393 x 852 logical pixels at 3x.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // Bluetooth scanning has no native side in tests.
    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('com.achyrio.vayu/ble_scan_events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    // Bluetooth scanning has no native side in tests.
    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('com.achyrio.vayu/ble_scan_events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    final platform = _SamplePlatform();
    late AppContainer container;
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 0x3c)),
            displayName: "Aarav's Pixel",
            platform: 'android',
            createdAt: DateTime(2026, 10, 1),
          ),
        ),
        platformService: platform,
        chatStorage: InMemoryChatStorage(chats),
        nfcPairingService: NfcPairingService(
          platformService: platform,
          platformAdapter: _SampleNfc(),
        ),
        settingsStorage: InMemorySettingsStorage(
          UserSettings(
            themePreference: theme,
            onboardingVersion: onboarded
                ? UserSettings.currentOnboardingVersion
                : 0,
            profileName: 'Aarav Mehta',
            profilePromptDismissed: true,
          ),
        ),
      );
      await container.initialize();
      await container.saveMyCard(
        const VayuCard(
          name: 'Aarav Mehta',
          title: 'Product Designer',
          company: 'Achyrio',
          phone: '+91 91234 56789',
          email: 'aarav@achyrio.com',
          website: 'achyrio.com',
          accent: 0,
        ),
      );
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: VayuApp(container: container),
      ),
    );
    return container;
  }

  void addPeers(AppContainer c) {
    for (final (id, name, transports) in [
      ('a1' * 16, "Riya's Galaxy S24", {TransportType.lan, TransportType.ble}),
      ('b2' * 16, "Kabir's Pixel 8", {TransportType.lan}),
    ]) {
      c.discoveryCoordinator.ingestPeerForTesting(
        DiscoveredPeer(
          deviceId: id,
          displayName: name,
          transportType: TransportType.lan,
          availableTransports: transports,
          rssi: -52,
          endpointAddress: '192.168.1.20:53531',
          transportEndpoints: {
            if (transports.contains(TransportType.lan))
              TransportType.lan: '192.168.1.20:53531',
            if (transports.contains(TransportType.ble))
              TransportType.ble: 'AA:BB:CC:DD:EE:01',
          },
          lastSeen: DateTime.now(),
        ),
      );
    }
  }

  /// A send in progress over a session that goes nowhere (test only).
  Future<OutboundTransferTask> liveTransfer(AppContainer c) async {
    const peerId = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
    c.fileSharingCoordinator.rememberPeer(
      DiscoveredPeer(
        deviceId: peerId,
        displayName: "Riya's Galaxy S24",
        transportType: TransportType.lan,
        rssi: -50,
        lastSeen: DateTime.now(),
      ),
    );
    const total = 1524000000;
    final task = OutboundTransferTask(
      transferId: 'c3' * 16,
      localDeviceId: '3c' * 16,
      remoteDeviceId: peerId,
      secureSession: _NowhereSession(peerId),
      source: _StalledSource(total),
      metadata: TransferMetadata(
        transferId: 'c3' * 16,
        fileName: 'Trip to Ladakh.mp4',
        totalBytes: total,
        chunkSize: 1024 * 1024,
        sha256Checksum: 'ab' * 32,
        mimeType: 'video/mp4',
      ),
    );
    await task.start();
    task.handleAck(
      TransferAckPayload(
        transferId: parseIdTo16Bytes('c3' * 16),
        ackType: TransferAckType.offerAccepted,
        highestContiguousChunkIndex: TransferAckPayload.noneAcked,
        bytesReceived: 0,
        selectiveBitmapOffset: 0,
        selectiveBitmap: Uint8List(0),
      ),
    );
    task.lastProgress = const TransferProgress(
      transferId: 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3',
      bytesTransferred: 929640000,
      totalBytes: total,
      currentChunkIndex: 886,
      speedBytesPerSecond: 41200000,
      etaSeconds: 15,
    );
    return task;
  }

  /// Lets real I/O finish and animations end, without waiting on spinners.
  Future<void> settle({int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> save(String name) async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${outDir.path}/$name.png')
          .writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Future<void> close(AppContainer c) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async => c.dispose());
  }
}

Future<void> _loadFonts() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent
          .parent
          .parent
          .parent
          .parent
          .parent
          .path;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> font(String file) async =>
      ByteData.sublistView(File('$dir/$file').readAsBytesSync());
  final roboto = FontLoader('Roboto');
  for (final f in [
    'roboto-light.ttf',
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
  ]) {
    roboto.addFont(font(f));
  }
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(font('materialicons-regular.otf'))).load();
}

class _SamplePlatform extends PlatformService {
  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: false,
        supportsNfc: true,
        hasCamera: true,
      );

  @override
  Future<SystemCapabilities> checkCapabilities() async =>
      const SystemCapabilities(
        platformName: 'android',
        bluetoothState: RadioState.enabled,
        nearbyPermission: PermissionStatus.granted,
        locationRequiredForBle: false,
        locationEnabled: true,
        wifiEnabled: true,
        lanState: NetworkState.lanAvailable,
      );

  @override
  Future<bool> isBleSupported() async => true;

  @override
  Future<bool> isWifiDirectSupported() async => false;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<PermissionReport> permissionReport() async => const PermissionReport(
    permissions: {
      PermissionGroup.nearby: PermissionStatus.granted,
      PermissionGroup.directWifi: PermissionStatus.granted,
      PermissionGroup.camera: PermissionStatus.notRequested,
      PermissionGroup.notifications: PermissionStatus.granted,
      PermissionGroup.storage: PermissionStatus.notRequired,
    },
    bluetooth: SwitchState.on,
    wifi: SwitchState.on,
    location: SwitchState.notNeeded,
    nfc: SwitchState.off,
    battery: SwitchState.off,
    sdkVersion: 34,
  );
}

class _SampleNfc implements NfcPlatformAdapter, CardSharingNfcAdapter {
  @override
  Future<bool> isNfcAvailable() async => true;

  @override
  Future<bool> isNfcEnabled() async => true;

  @override
  Future<void> startListening({
    required void Function(Uint8List ndefBytes) onTagDiscovered,
  }) async {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> writeNdef(Uint8List ndefBytes) async {}

  @override
  Future<void> serveCard(Uint8List vcard) async {}

  @override
  Future<void> stopServing() async {}
}

class _NowhereSession implements SecureSession {
  @override
  final String remoteDeviceId;

  _NowhereSession(this.remoteDeviceId);

  @override
  String get sessionId => 'd4' * 16;

  @override
  SessionState get state => SessionState.secured;

  @override
  bool get isEstablished => true;

  @override
  Stream<VayuPacket> get incomingDecryptedPackets => const Stream.empty();

  @override
  Future<void> sendEncryptedPacket(VayuPacket packet) async {}

  @override
  Future<Uint8List> encryptPayload(
    Uint8List plaintext, {
    Uint8List? associatedData,
  }) async => plaintext;

  @override
  Future<Uint8List> decryptPayload(
    Uint8List ciphertext, {
    Uint8List? associatedData,
  }) async => ciphertext;

  @override
  Future<void> terminate() async {}
}

/// Never delivers a chunk, so the sample transfer stays where it is.
class _StalledSource implements PayloadSource {
  @override
  final int length;

  _StalledSource(this.length);

  @override
  Future<Uint8List> readChunk(int offset, int length) =>
      Completer<Uint8List>().future;

  @override
  Stream<Uint8List> openStream({int startByte = 0}) => const Stream.empty();

  @override
  Future<String> computeSha256() async => 'ab' * 32;

  @override
  Future<void> close() async {}
}
