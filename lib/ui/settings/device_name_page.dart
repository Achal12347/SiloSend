import 'package:flutter/material.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Changes the name nearby phones see. Saving re-advertises it immediately.
class DeviceNamePage extends StatefulWidget {
  final AppContainer container;

  const DeviceNamePage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DeviceNamePage(container: container)),
      );

  @override
  State<DeviceNamePage> createState() => _DeviceNamePageState();
}

class _DeviceNamePageState extends State<DeviceNamePage> {
  late final String _currentName = widget.container.identity?.displayName ?? '';
  late final TextEditingController _controller = TextEditingController(
    text: _currentName,
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
    if (newName == _currentName) {
      navigator.pop();
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.container.updateCustomDisplayName(newName);
      navigator.pop();
      showVayuNotice(null, 'Name saved', tone: VayuNoticeTone.success);
    } catch (e) {
      AppLogger.warning('DeviceName', 'Rename failed: $e');
      if (mounted) setState(() => _saving = false);
      showVayuNotice(null, friendlyError(e), tone: VayuNoticeTone.problem);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phone name')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _controller,
                autofocus: true,
                maxLength: 32,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  labelText: 'Name nearby phones see',
                ),
                validator: (value) =>
                    (value?.trim() ?? '').isEmpty ? 'Enter a name' : null,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
