import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';

/// Generic single-text-field dialog used for renaming.
/// Pops with the trimmed new value on success, or `null` if cancelled.
///
/// onSubmit, performs the action and returns `null` on success, or an error
/// message to display inline. If emptyError is set, an empty input is rejected
/// with that message before onSubmit is called.
class RenameDialog extends StatefulWidget {
  final String title;
  final String hintText;
  final String initialValue;
  final String? emptyError;
  final int? maxLength;
  final Future<String?> Function(String value) onSubmit;

  const RenameDialog({
    super.key,
    required this.title,
    required this.hintText,
    required this.initialValue,
    required this.onSubmit,
    this.emptyError,
    this.maxLength,
  });

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final value = _controller.text.trim();
    if (widget.emptyError != null && value.isEmpty) {
      setState(() => _error = widget.emptyError);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSubmit(value);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _error = error;
        _saving = false;
      });
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RoundedInputField(
            controller: _controller,
            hintText: widget.hintText,
            maxLength: widget.maxLength,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(context).pop(),
          label: context.l10n.cancel,
          color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
        ),
        if (_saving)
          const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
        else
          SoftButton(
            onPressed: _submit,
            label: context.l10n.save,
            color: GlobalThemeData.darkColorScheme.primary,
          ),
      ],
    );
  }
}
