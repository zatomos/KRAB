import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/pages/instance_setup_page.dart';
import 'package:krab/services/instance/active_instance.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/soft_button.dart';

/// Disconnects from the current instance so the user can connect to another.
///
/// Each instance owns its own client and session, so this no longer has to
/// restart the app the way it did when one process meant one backend: signing
/// out and dropping the instance is enough, and the connect screen opens
/// straight away.
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

    final instance = activeInstance;

    // Best-effort sign-out; a failure here must not block the switch.
    final res = await instance.api.logOut();
    if (!res.success) {
      debugPrint('Change server: sign-out failed (${res.error})');
    }

    // Drops the session, the caches and the entry itself.
    await InstanceRegistry.instance.remove(instance.id);

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const InstanceSetupPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.change_server_title),
      content: Text(context.l10n.change_server_description),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: _working ? () {} : () => Navigator.of(context).pop(),
          label: context.l10n.cancel,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            icon: Icons.logout,
            color: Theme.of(context).colorScheme.primary,
          ),
      ],
    );
  }
}
