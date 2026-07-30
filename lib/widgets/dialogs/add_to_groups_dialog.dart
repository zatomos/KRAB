import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/group.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/widgets/soft_button.dart';

/// Lets the uploader pick which additional groups to share an existing image to.
/// groups should already be filtered to the groups the image isn't in yet.
///
/// Returns the chosen groups, or null if cancelled.
Future<List<Group>?> showAddToGroupsDialog(
  BuildContext context, {
  required List<Group> groups,
}) {
  return showDialog<List<Group>>(
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
  /// Ticked groups, as `instanceId/groupId`.
  final Set<String> _selected = {};

  static String _keyOf(Group group) => '${group.instanceId}/${group.id}';

  /// The groups in the order given, headed by the server that owns them.
  List<Widget> _rows() {
    final byInstance = <String, List<Group>>{};
    for (final group in widget.groups) {
      (byInstance[group.instanceId] ??= []).add(group);
    }

    final rows = <Widget>[];
    for (final entry in byInstance.entries) {
      if (byInstance.length > 1) {
        final instance = InstanceRegistry.instance.byId(entry.key);
        rows.add(_instanceHeader(instance?.label ?? entry.key));
      }
      rows.addAll(entry.value.map(_groupTile));
    }
    return rows;
  }

  Widget _instanceHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                  letterSpacing: GlobalThemeData.mediumTracking,
                ),
          ),
        ),
      );

  Widget _groupTile(Group group) => CheckboxListTile(
        value: _selected.contains(_keyOf(group)),
        onChanged: (checked) => setState(() {
          if (checked == true) {
            _selected.add(_keyOf(group));
          } else {
            _selected.remove(_keyOf(group));
          }
        }),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        secondary: GroupAvatar(group, radius: 18),
        title: Text(group.name, overflow: TextOverflow.ellipsis),
      );

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
                children: _rows(),
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
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        SoftButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(widget.groups
                  .where((g) => _selected.contains(_keyOf(g)))
                  .toList()),
          label: context.l10n.add,
          icon: Icons.add,
          color: _selected.isEmpty
              ? Theme.of(context)
                  .colorScheme
                  .onSurfaceVariant
                  .withValues(alpha: 0.4)
              : Theme.of(context).colorScheme.primary,
        ),
      ],
    );
  }
}
