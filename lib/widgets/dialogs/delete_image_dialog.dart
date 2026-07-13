import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/group.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/widgets/soft_button.dart';

/// Lets the uploader pick which groups to remove a photo from. Selecting every
/// group removes it from all of them, which deletes the photo outright.
/// Only shown when the photo is shared to more than one group;
/// returns the chosen group ids, or null if cancelled.
Future<Set<String>?> showDeleteImageDialog(
  BuildContext context, {
  required List<Group> groups,
  String? currentGroupId,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (_) => _DeleteImageDialog(
      groups: groups,
      currentGroupId: currentGroupId,
    ),
  );
}

class _DeleteImageDialog extends StatefulWidget {
  final List<Group> groups;
  final String? currentGroupId;

  const _DeleteImageDialog({required this.groups, this.currentGroupId});

  @override
  State<_DeleteImageDialog> createState() => _DeleteImageDialogState();
}

class _DeleteImageDialogState extends State<_DeleteImageDialog> {
  late final Set<String> _selected = {
    // Preselect the group being viewed, if any.
    if (widget.currentGroupId != null &&
        widget.groups.any((g) => g.id == widget.currentGroupId))
      widget.currentGroupId!,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.delete_photo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
            child: Text(context.l10n.remove_from_groups_message),
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
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
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
          label: context.l10n.remove,
          icon: Icons.delete_forever,
          color: _selected.isEmpty
              ? GlobalThemeData.darkColorScheme.onSurfaceVariant
                  .withValues(alpha: 0.4)
              : GlobalThemeData.darkColorScheme.error,
        ),
      ],
    );
  }
}
