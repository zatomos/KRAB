import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/group.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/dialogs/rename_dialog.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/home_widget_updater.dart';

enum GroupAction { favorite, mute, rename, leave, delete }

Future<GroupAction?> showGroupActions(
  BuildContext context, {
  required Group group,
  required bool isFavorite,
  required bool isMuted,
  required bool canRename,
  required bool canDelete,
  required Rect anchor,
}) {
  final l10n = context.l10n;
  final scheme = Theme.of(context).colorScheme;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

  PopupMenuItem<GroupAction> item(
          IconData icon, String label, GroupAction value,
          {Color? color}) =>
      PopupMenuItem(
        value: value,
        child: ListTile(
          leading: Icon(icon, color: color),
          title: Text(label,
              style: TextStyle(fontWeight: FontWeight.w400, color: color)),
          onTap: () => Navigator.pop(context, value),
        ),
      );

  return showMenu<GroupAction>(
    context: context,
    color: scheme.surfaceContainer,
    position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
    items: [
      item(
        Symbols.star_rounded,
        isFavorite ? l10n.unfavorite_group : l10n.favorite_group,
        GroupAction.favorite,
        color: isFavorite ? Colors.amber : null,
      ),
      item(
        isMuted
            ? Symbols.notifications_active_rounded
            : Symbols.notifications_off_rounded,
        isMuted ? l10n.unmute_group : l10n.mute_group,
        GroupAction.mute,
      ),
      if (canRename)
        item(Symbols.edit_rounded, l10n.edit_group_name, GroupAction.rename),
      item(Symbols.logout_rounded, l10n.leave_group, GroupAction.leave,
          color: scheme.error),
      if (canDelete)
        item(Symbols.delete_rounded, l10n.delete_group, GroupAction.delete,
            color: scheme.error),
    ],
  );
}

class GroupActions {
  const GroupActions(this.context, this.instance, this.group);

  final BuildContext context;
  final KrabInstance instance;
  final Group group;

  AppLocalizations get _l10n => context.l10n;

  Future<String?> rename() async {
    final l10n = _l10n;
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        title: l10n.edit_group_name,
        hintText: l10n.new_group_name,
        initialValue: group.name,
        emptyError: l10n.group_name_empty,
        maxLength: 19,
        onSubmit: (value) async {
          final res = await instance.api.updateGroupName(group.id, value);
          return res.success ? null : describeError(l10n, res.error);
        },
      ),
    );
    if (newName == null || !context.mounted) return null;
    showSnackBar(l10n.group_name_updated_success, tone: SnackTone.success);
    return newName;
  }

  Future<bool> leave({bool confirm = true}) async {
    final l10n = _l10n;
    if (confirm) {
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.leave_group,
        message: l10n.leave_group_confirmation,
        confirmLabel: l10n.leave_group,
        destructive: true,
      );
      if (!confirmed || !context.mounted) return false;
    }

    final response = await instance.api.leaveGroup(group.id);
    if (!context.mounted) return false;
    if (!response.success) {
      showSnackBar(l10n.error_leaving_group(context.errorText(response.error)),
          tone: SnackTone.failure);
      return false;
    }
    await _forget();
    if (!context.mounted) return true;
    showSnackBar(l10n.left_group_success, tone: SnackTone.success);
    return true;
  }

  Future<bool> delete({bool confirm = true}) async {
    final l10n = _l10n;
    if (confirm) {
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.delete_group,
        message: l10n.delete_group_confirmation,
        confirmLabel: l10n.delete_group,
        destructive: true,
      );
      if (!confirmed || !context.mounted) return false;
    }

    final res = await instance.api.deleteGroup(group.id);
    if (!context.mounted) return false;
    if (!res.success) {
      showSnackBar(l10n.error_deleting_group(context.errorText(res.error)),
          tone: SnackTone.failure);
      return false;
    }
    await _forget();
    if (!context.mounted) return true;
    showSnackBar(l10n.group_deleted_success, tone: SnackTone.success);
    return true;
  }

  Future<void> _forget() async {
    await UserPreferences.removeFavoriteGroup(group.instanceId, group.id);
    cacheUserGroupsForWidget();
  }
}
