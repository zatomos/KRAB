import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';

class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key, required this.username});

  final String username;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _controller = TextEditingController();
  bool _matches = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    final matches = _controller.text.trim() == widget.username;
    if (matches != _matches) setState(() => _matches = matches);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = GlobalThemeData.darkColorScheme.error;
    return AlertDialog(
      title: Text(context.l10n.delete_account),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.delete_account_confirmation),
          const SizedBox(height: 16),
          Text(context.l10n.delete_account_type_confirm(widget.username)),
          const SizedBox(height: 8),
          RoundedInputField(
            controller: _controller,
            hintText: context.l10n.username,
            maxLength: 19,
          ),
        ],
      ),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: () => Navigator.pop(context),
          label: context.l10n.cancel,
          color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
        ),
        SoftButton(
          onPressed: _matches ? () => Navigator.pop(context, true) : null,
          label: context.l10n.delete_account,
          icon: Icons.delete_forever,
          color: _matches ? errorColor : errorColor.withValues(alpha: 0.4),
        ),
      ],
    );
  }
}
