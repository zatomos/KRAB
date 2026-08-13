import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';

/// Shows a destructive confirmation dialog that only unlocks once the user
/// types expectedText.
Future<bool> showTypeToConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String prompt,
  required String expectedText,
  required String hintText,
  required String confirmLabel,
  int? maxLength,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => TypeToConfirmDialog(
      title: title,
      message: message,
      prompt: prompt,
      expectedText: expectedText,
      hintText: hintText,
      confirmLabel: confirmLabel,
      maxLength: maxLength,
    ),
  );
  return result ?? false;
}

class TypeToConfirmDialog extends StatefulWidget {
  const TypeToConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.prompt,
    required this.expectedText,
    required this.hintText,
    required this.confirmLabel,
    this.maxLength,
  });

  final String title;
  final String message;

  /// Tells the user what to type.
  final String prompt;
  final String expectedText;
  final String hintText;
  final String confirmLabel;
  final int? maxLength;

  @override
  State<TypeToConfirmDialog> createState() => _TypeToConfirmDialogState();
}

class _TypeToConfirmDialogState extends State<TypeToConfirmDialog> {
  final _controller = TextEditingController();
  bool _matches = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    final matches = _controller.text.trim() == widget.expectedText;
    if (matches != _matches) setState(() => _matches = matches);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 16),
          Text(widget.prompt),
          const SizedBox(height: 8),
          RoundedInputField(
            controller: _controller,
            hintText: widget.hintText,
            maxLength: widget.maxLength,
          ),
        ],
      ),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: () => Navigator.pop(context),
          label: context.l10n.cancel,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        SoftButton(
          onPressed: _matches ? () => Navigator.pop(context, true) : null,
          label: widget.confirmLabel,
          icon: Icons.delete_forever,
          color: _matches ? errorColor : errorColor.withValues(alpha: 0.4),
        ),
      ],
    );
  }
}
