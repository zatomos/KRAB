import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';

/// Change-password dialog. Pops with true on success so the caller
/// can show a confirmation.
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key});

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  String? _error;
  bool _saving = false;
  bool _showCurrent = false;
  bool _showNew = false;
  bool _showConfirm = false;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String _localizeAuthError(String? error) {
    switch (error) {
      case 'invalid_email_or_password':
        return context.l10n.invalid_email_or_password;
      case 'email_already_exists':
        return context.l10n.email_already_exists;
      case 'password_too_weak':
        return context.l10n.password_too_weak;
      default:
        return error ?? '';
    }
  }

  Future<void> _save() async {
    final current = _currentController.text;
    final next = _newController.text;
    final confirm = _confirmController.text;

    if (current.isEmpty || next.isEmpty || confirm.isEmpty) {
      setState(() => _error = context.l10n.fill_in_all_fields);
      return;
    }
    if (next != confirm) {
      setState(() => _error = context.l10n.passwords_do_not_match);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final response = await changePassword(current, next);
    if (!mounted) return;

    if (response.success) {
      TextInput.finishAutofillContext(shouldSave: true);
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = _localizeAuthError(response.error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.change_password),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RoundedInputField(
                controller: _currentController,
                hintText: context.l10n.current_password,
                obscureText: !_showCurrent,
                icon: const Icon(Icons.lock_rounded),
                suffixIcon: IconButton(
                  icon: Icon(_showCurrent
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded),
                  onPressed: () => setState(() => _showCurrent = !_showCurrent),
                ),
              ),
              AutofillGroup(
                onDisposeAction: AutofillContextAction.cancel,
                child: Column(
                  children: [
                    RoundedInputField(
                      controller: _newController,
                      hintText: context.l10n.new_password,
                      obscureText: !_showNew,
                      icon: const Icon(Icons.key_rounded),
                      autofillHints: const [AutofillHints.newPassword],
                      suffixIcon: IconButton(
                        icon: Icon(_showNew
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded),
                        onPressed: () => setState(() => _showNew = !_showNew),
                      ),
                    ),
                    RoundedInputField(
                      controller: _confirmController,
                      hintText: context.l10n.confirm_new_password,
                      obscureText: !_showConfirm,
                      errorText: _error,
                      icon: const Icon(Icons.check_rounded),
                      autofillHints: const [AutofillHints.newPassword],
                      suffixIcon: IconButton(
                        icon: Icon(_showConfirm
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded),
                        onPressed: () =>
                            setState(() => _showConfirm = !_showConfirm),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: () => Navigator.pop(context),
          label: context.l10n.cancel,
          color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
        ),
        if (_saving)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          SoftButton(
            label: context.l10n.save,
            onPressed: _save,
            color: GlobalThemeData.darkColorScheme.primary,
            icon: Icons.check_rounded,
          ),
      ],
    );
  }
}
