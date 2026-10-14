import 'package:flutter/material.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Bottom sheet to change the name nearby devices see. Saving re-advertises
/// the new name immediately.
Future<void> showRenameDeviceSheet(
  BuildContext context, {
  required AppContainer container,
  required String currentName,
}) {
  return showVayuSheet<void>(
    context: context,
    builder: (_) =>
        _RenameDeviceSheet(container: container, currentName: currentName),
  );
}

class _RenameDeviceSheet extends StatefulWidget {
  final AppContainer container;
  final String currentName;

  const _RenameDeviceSheet({
    required this.container,
    required this.currentName,
  });

  @override
  State<_RenameDeviceSheet> createState() => _RenameDeviceSheetState();
}

class _RenameDeviceSheetState extends State<_RenameDeviceSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentName,
  );
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_formKey.currentState?.validate() != true) return;
    final newName = _controller.text.trim();
    final navigator = Navigator.of(context);
    if (newName == widget.currentName) {
      navigator.pop();
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.container.updateCustomDisplayName(newName);
      navigator.pop();
      showVayuNotice(null, 'Name saved', tone: VayuNoticeTone.success);
    } catch (e) {
      AppLogger.warning('RenameDevice', 'Rename failed: $e');
      if (mounted) setState(() => _saving = false);
      showVayuNotice(null, friendlyError(e), tone: VayuNoticeTone.problem);
    }
  }

  @override
  Widget build(BuildContext context) {
    return VayuSheet(
      title: 'Device name',
      message: 'This is how nearby phones see you.',
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          maxLength: 32,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _save(),
          decoration: const InputDecoration(
            hintText: 'For example, Living room tablet',
          ),
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) return 'Enter a name';
            return null;
          },
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
