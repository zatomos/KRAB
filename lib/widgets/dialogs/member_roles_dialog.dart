import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/soft_button.dart';

/// Explains what each role is allowed to do
Future<void> showMemberRolesDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.member_roles_title),
        content: SizedBox(
          width: MediaQuery.sizeOf(context).width,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RoleSection(
                  icon: Symbols.crown_rounded,
                  color: Colors.amber,
                  role: context.l10n.role_owner,
                  description: context.l10n.role_owner_info,
                ),
                const SizedBox(height: 20),
                _RoleSection(
                  icon: Symbols.shield_person_rounded,
                  color: Colors.blue,
                  role: context.l10n.role_admin,
                  description: context.l10n.role_admin_info,
                ),
              ],
            ),
          ),
        ),
        actionsOverflowButtonSpacing:
            GlobalThemeData.dialogActionsOverflowSpacing,
        actions: [
          SoftButton(
            onPressed: () => Navigator.of(context).pop(),
            label: context.l10n.got_it,
            color: Theme.of(context).colorScheme.primary,
          ),
        ],
      ),
    );

class _RoleSection extends StatelessWidget {
  const _RoleSection({
    required this.icon,
    required this.color,
    required this.role,
    required this.description,
  });

  final IconData icon;
  final Color color;
  final String role;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, fill: 1, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                role,
                style: TextStyle(
                  color: color,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          description,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}
