import 'package:flutter/material.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/platform/contact_picker.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/transfer/selected_items_page.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/widgets/peer_picker_sheet.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// What the user can start from Home and the Nearby devices page.
///
/// Moved out of the home screen so both screens behave the same way.
class ShareActions {
  ShareActions._();

  static void _problem(BuildContext context, String message) =>
      showVayuNotice(context, message, tone: VayuNoticeTone.problem);

  /// Send: choose Files or Folder, pick them, review them, then
  /// choose the device (with Scan QR). With [receiverCode] the device is
  /// already known and is joined as soon as the items are chosen.
  static Future<void> send(
    BuildContext context,
    AppContainer container, {
    String? receiverCode,
    String title = 'Send',
  }) async {
    final choice = await showVayuSheet<_SendKind>(
      context: context,
      builder: (sheetContext) => VayuSheet(
        title: title,
        content: Column(
          children: [
            _ChoiceTile(
              icon: Icons.insert_drive_file_outlined,
              title: 'Files',
              subtitle: 'Photos, videos, documents, anything',
              onTap: () => Navigator.of(sheetContext).pop(_SendKind.files),
            ),
            const SizedBox(height: 8),
            _ChoiceTile(
              icon: Icons.folder_outlined,
              title: 'Folder',
              subtitle: 'Arrives with the same folders inside',
              onTap: () => Navigator.of(sheetContext).pop(_SendKind.folder),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case _SendKind.files:
        await sendFiles(context, container, receiverCode: receiverCode);
      case _SendKind.folder:
        await sendFolder(context, container, receiverCode: receiverCode);
    }
  }

  /// A Receive code opened from outside Vayu (the phone's own camera app
  /// scanned it): choose what to send, then it goes to that phone.
  static Future<void> sendToCode(
    BuildContext context,
    AppContainer container,
    String code,
  ) async {
    final PairingPayload payload;
    try {
      payload = PairingPayload.fromUri(Uri.parse(code));
    } on FormatException {
      _problem(context, "That code isn't a Vayu Receive code.");
      return;
    }
    await send(
      context,
      container,
      receiverCode: code,
      title: 'Send to ${payload.displayName}',
    );
  }

  static Future<void> sendFiles(
    BuildContext context,
    AppContainer container, {
    String? receiverCode,
  }) async {
    try {
      final docs = await container.filePickerService.pickMultipleDocuments();
      if (docs.isNotEmpty && context.mounted) {
        await SelectedItemsPage.open(
          context,
          documents: docs,
          container: container,
          receiverCode: receiverCode,
        );
      }
    } catch (_) {
      if (context.mounted) {
        _problem(context, "Couldn't open your files. Please try again.");
      }
    }
  }

  /// The receiver gets the same folder structure.
  static Future<void> sendFolder(
    BuildContext context,
    AppContainer container, {
    String? receiverCode,
  }) async {
    try {
      final folder = await container.filePickerService.pickFolder();
      if (folder == null || !context.mounted) return;
      if (folder.documents.isEmpty) {
        showVayuNotice(context, '"${folder.name}" has no files to send');
        return;
      }
      if (folder.truncated) {
        showVayuNotice(
          context,
          'Only the first ${folder.documents.length} files of "${folder.name}" will be sent',
        );
      }
      await SelectedItemsPage.open(
        context,
        documents: folder.documents,
        container: container,
        folderName: folder.name,
        receiverCode: receiverCode,
      );
    } catch (_) {
      if (context.mounted) {
        _problem(context, "Couldn't open that folder. Please try again.");
      }
    }
  }

  /// One contact from the system picker; null when the user backs out.
  static Future<PickedContact?> pickContact(BuildContext context) async {
    try {
      return await const ContactPicker().pick();
    } on ContactPickerException catch (e) {
      if (context.mounted) {
        _problem(
          context,
          e.isPermissionDenied
              ? 'Vayu needs access to the contact you choose to share it.'
              : 'Could not open contacts.',
        );
      }
      return null;
    }
  }

  /// Contact first, then the device (nearby list or Scan QR).
  static Future<void> shareContact(
    BuildContext context,
    AppContainer container,
  ) async {
    final contact = await pickContact(context);
    if (contact == null || !context.mounted) return;
    final peer = await pickNearbyPeer(
      context,
      container: container,
      title: 'Send ${contact.name} to',
    );
    if (peer == null || !context.mounted) return;
    await _sendContact(context, container, peer, contact);
  }

  /// A contact to a device already chosen (its row on Home or Nearby).
  static Future<void> sendContactTo(
    BuildContext context,
    AppContainer container,
    DiscoveredPeer peer,
  ) async {
    final contact = await pickContact(context);
    if (contact == null || !context.mounted) return;
    await _sendContact(context, container, peer, contact);
  }

  static Future<void> _sendContact(
    BuildContext context,
    AppContainer container,
    DiscoveredPeer peer,
    PickedContact contact,
  ) async {
    try {
      final task = await container.fileSharingCoordinator.sendContactToPeer(
        peer,
        name: contact.name,
        vcard: contact.vcard,
      );
      if (context.mounted) {
        await TransferDetailPage.open(context, container, task: task);
      }
    } catch (e) {
      if (context.mounted) _problem(context, friendlyError(e));
    }
  }

  /// Files to a device already chosen.
  static Future<void> sendFilesTo(
    BuildContext context,
    AppContainer container,
    DiscoveredPeer peer,
  ) async {
    try {
      final task = await container.fileSharingCoordinator.sendFileToPeer(peer);
      if (task != null && context.mounted) {
        await TransferDetailPage.open(
          context,
          container,
          transferId: task.transferId,
        );
      }
    } catch (e) {
      if (context.mounted) {
        _problem(context, friendlyError(e, peerName: peer.displayName));
      }
    }
  }

  /// Opens a secure connection without sending anything yet.
  static Future<void> connect(
    BuildContext context,
    AppContainer container,
    DiscoveredPeer peer,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await container.connectToPeer(peer);
      showVayuNotice(
        null,
        messenger: messenger,
        'Connected to ${peer.displayName}',
        tone: VayuNoticeTone.success,
      );
    } catch (_) {
      showVayuNotice(
        null,
        messenger: messenger,
        'Could not reach ${peer.displayName}. Move closer and try again.',
        tone: VayuNoticeTone.problem,
      );
    }
  }
}

enum _SendKind { files, folder }

class _ChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(icon, color: theme.colorScheme.onSurface),
        title: Text(title, style: theme.textTheme.titleMedium),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}
