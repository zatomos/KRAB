import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/background_session.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';

/// Re-auth prompt to re-establish the independent background session
Future<void> showReauthPromptIfNeeded(BuildContext context) async {
  if (_reauthDialogShowing) return;
  final user = supabase.auth.currentUser;
  final email = user?.email;
  if (email == null) return;
  if (await BackgroundSession.hasSession()) return;
  if (!context.mounted) return;

  _reauthDialogShowing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReauthDialog(email: email),
    );
  } finally {
    _reauthDialogShowing = false;
  }
}

/// Guards against stacking duplicate dialogs when the prompt is triggered from
/// both startup and an app-resume in quick succession
bool _reauthDialogShowing = false;

class _ReauthDialog extends StatefulWidget {
  const _ReauthDialog({required this.email});

  final String email;

  @override
  State<_ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<_ReauthDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  bool _saving = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final password = _controller.text;
    if (password.isEmpty) {
      setState(() => _error = context.l10n.fill_in_all_fields);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await BackgroundSession.mintAndStore(widget.email, password);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = context.l10n.invalid_email_or_password;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.l10n.reauth_prompt_title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(context.l10n.reauth_prompt_message,
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 16),
              RoundedInputField(
                controller: _controller,
                hintText: context.l10n.password,
                obscureText: !_showPassword,
                errorText: _error,
                icon: const Icon(Icons.lock_rounded),
                suffixIcon: IconButton(
                  icon: Icon(_showPassword
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SoftButton(
                    onPressed: () => Navigator.pop(context),
                    label: context.l10n.later,
                    color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  if (_saving)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    SoftButton(
                      label: context.l10n.confirm,
                      onPressed: _confirm,
                      color: GlobalThemeData.darkColorScheme.primary,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
