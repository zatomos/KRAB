import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/group.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/widgets/soft_button.dart';

/// Lets the uploader pick which additional groups to share an existing photo to.
/// [groups] should already be filtered to the groups the photo isn't in yet.
/// Returns the chosen group ids, or null if cancelled.
Future<Set<String>?> showAddToGroupsDialog(
  BuildContext context, {
  required List<Group> groups,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (_) => _AddToGroupsDialog(groups: groups),
  );
}

class _AddToGroupsDialog extends StatefulWidget {
  final List<Group> groups;

  const _AddToGroupsDialog({required this.groups});

  @override
  State<_AddToGroupsDialog> createState() => _AddToGroupsDialogState();
}

class _AddToGroupsDialogState extends State<_AddToGroupsDialog> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.add_to_group),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
            child: Text(context.l10n.add_to_groups_message),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final group in widget.groups)
                    CheckboxListTile(
                      value: _selected.contains(group.id),
                      onChanged: (checked) => setState(() {
                        if (checked == true) {
                          _selected.add(group.id);
                        } else {
                          _selected.remove(group.id);
                        }
                      }),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      secondary: GroupAvatar(group, radius: 18),
                      title: Text(group.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(context).pop(),
          label: context.l10n.cancel,
          color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
        ),
        SoftButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(Set.of(_selected)),
          label: context.l10n.add,
          color: _selected.isEmpty
              ? GlobalThemeData.darkColorScheme.onSurfaceVariant
              : GlobalThemeData.darkColorScheme.primary,
        ),
      ],
    );
  }
}
