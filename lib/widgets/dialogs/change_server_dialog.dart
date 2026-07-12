import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/widgets/soft_button.dart';

/// Disconnects from the current instance so the user can connect to another.
///
/// Switching backend cannot happen live: Supabase is initialised once per
/// process against one URL, and there is no supported way to re-init it. So this
/// signs out, clears the saved instance, and closes the app; the next launch
/// finds no instance and comes up on the connect screen, where the user picks a
/// new one (token or manual).
class ChangeServerDialog extends StatefulWidget {
  const ChangeServerDialog({super.key});

  @override
  State<ChangeServerDialog> createState() => _ChangeServerDialogState();
}

class _ChangeServerDialogState extends State<ChangeServerDialog> {
  bool _working = false;

  Future<void> _disconnect() async {
    if (_working) return;
    setState(() => _working = true);

    // Best-effort sign-out; a failure here must not block the switch.
    try {
      await logOut();
    } catch (_) {}

    // Clearing the saved instance is what sends the next launch to the connect
    // screen instead of straight to login.
    await UserPreferences.setSupabaseConfig(url: '', anonKey: '');

    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.change_server_title),
      content: Text(context.l10n.change_server_description),
      actions: [
        SoftButton(
          onPressed: _working ? () {} : () => Navigator.of(context).pop(),
          label: context.l10n.cancel,
          color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
        ),
        if (_working)
          const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
        else
          SoftButton(
            onPressed: _disconnect,
            label: context.l10n.change_server_confirm,
            color: GlobalThemeData.darkColorScheme.primary,
          ),
      ],
    );
  }
}
