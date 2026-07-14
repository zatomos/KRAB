import 'package:flutter/material.dart';

import 'package:krab/services/auth/app_auth.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/widgets/dialogs/member_roles_dialog.dart';
import 'package:krab/widgets/dialogs/edit_avatar_dialog.dart';
import 'package:krab/widgets/dialogs/rename_dialog.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/group_member.dart';
import 'package:krab/pages/group_invites_page.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/l10n/l10n.dart';

class GroupSettingsPage extends StatefulWidget {
  final Group group;

  const GroupSettingsPage({super.key, required this.group});

  @override
  GroupSettingsPageState createState() => GroupSettingsPageState();
}

class GroupSettingsPageState extends State<GroupSettingsPage> {
  late Group _group;
  late Future<SupabaseResponse<List<GroupMember>>> _membersFuture;
  late String? _currentUserId;
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _membersFuture = getGroupMembers(_group.id);
    _currentUserId = AppAuth.instance.currentUserId;
    UserPreferences.isGroupMuted(_group.id).then((muted) {
      if (mounted) setState(() => _muted = muted);
    });
  }

  Future<void> _toggleMuted(bool muted) async {
    setState(() => _muted = muted);
    await UserPreferences.setGroupMuted(_group.id, muted);
  }

  String _getCurrentUserRole(List<GroupMember> members) {
    if (_currentUserId == null) return 'member';

    final me = members.firstWhere(
      (m) => m.user.id == _currentUserId,
      orElse: () => GroupMember.empty(),
    );

    return me.role;
  }

  Future<void> _leaveGroup() async {
    final response = await leaveGroup(widget.group.id);
    if (!mounted) return;
    if (response.success) {
      // Only once the server agrees we've left.
      await UserPreferences.removeFavoriteGroup(widget.group.id);
      if (!mounted) return;
      cacheUserGroupsForWidget();
      showSnackBar(context.l10n.left_group_success, tone: SnackTone.success);
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      showSnackBar(
          context.l10n.error_leaving_group(context.errorText(response.error)),
          tone: SnackTone.failure);
    }
  }

  Future<void> _updateGroupName() async {
    final l10n = context.l10n;
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        title: l10n.edit_group_name,
        hintText: l10n.new_group_name,
        initialValue: _group.name,
        emptyError: l10n.group_name_empty,
        maxLength: 19,
        onSubmit: (value) async {
          final res = await updateGroupName(_group.id, value);
          return res.success ? null : describeError(l10n, res.error);
        },
      ),
    );
    if (newName == null || !mounted) return;
    setState(() => _group = _group.copyWith(name: newName));
    showSnackBar(context.l10n.group_name_updated_success,
        tone: SnackTone.success);
  }

  Future<void> openEditIconDialog() async {
    final l10n = context.l10n;
    final change = await editAvatar(
      context,
      AvatarTarget(
        hasImage: _group.iconUrl?.isNotEmpty ?? false,
        dialogTitle: l10n.edit_icon_title,
        upload: (image) => editGroupIcon(image, _group.id),
        remove: () => deleteGroupIcon(_group.id),
        freshUrl: () => getGroupIconUrl(_group.id),
        uploadFailed: l10n.error_updating_icon,
        removeFailed: l10n.error_deleting_icon,
        uploadSucceeded: l10n.icon_updated_success,
        removeSucceeded: l10n.icon_deleted_success,
      ),
    );
    if (change == null || !mounted) return;
    // A deleted icon is the empty string here, not null: the Group model uses
    // null to mean "unchanged" in copyWith.
    setState(() => _group = _group.copyWith(iconUrl: change.url ?? ''));
  }

  /// Confirm a moderation action, apply it, and reload the member list.
  Future<void> _confirmMemberAction({
    required String title,
    required String message,
    required Future<SupabaseResponse<String>> Function() apply,
    required String success,
    required String Function(String error) failure,
  }) async {
    final confirmed = await showConfirmDialog(context,
        title: title, message: message, confirmLabel: context.l10n.confirm);
    if (!confirmed || !mounted) return;

    final res = await apply();
    if (!mounted) return;
    if (res.success) {
      showSnackBar(success, tone: SnackTone.success);
      setState(() => _membersFuture = getGroupMembers(_group.id));
    } else {
      showSnackBar(failure(context.errorText(res.error)),
          tone: SnackTone.failure);
    }
  }

  Future<void> _manageUserRoleDialog(String userId, String action) {
    final l10n = context.l10n;
    final title = {
      "promote_admin": l10n.promote_user,
      "demote": l10n.demote_user,
      "transfer_ownership": l10n.transfer_ownership,
    }[action]!;
    final message = {
      "promote_admin": l10n.promote_user_confirmation,
      "demote": l10n.demote_user_confirmation,
      "transfer_ownership": l10n.transfer_ownership_confirmation,
    }[action]!;

    return _confirmMemberAction(
      title: title,
      message: message,
      apply: () => changeMemberRole(_group.id, userId, action),
      success: l10n.user_role_updated_success,
      failure: l10n.error_updating_user_role,
    );
  }

  Future<void> _manageUserBanDialog(String userId) => _confirmMemberAction(
        title: context.l10n.ban_user,
        message: context.l10n.ban_user_confirmation,
        apply: () => banUser(_group.id, userId),
        success: context.l10n.user_banned_success,
        failure: context.l10n.error_banning_user,
      );

  Future<void> _manageUserUnbanDialog(String userId) => _confirmMemberAction(
        title: context.l10n.unban_user,
        message: context.l10n.unban_user_confirmation,
        apply: () => unbanUser(_group.id, userId),
        success: context.l10n.user_unbanned_success,
        failure: context.l10n.error_unbanning_user,
      );

  Future<void> _deleteGroup() async {
    final confirm = await showConfirmDialog(context,
        title: context.l10n.delete_group,
        message: context.l10n.delete_group_confirmation,
        confirmLabel: context.l10n.delete,
        destructive: true);
    if (!confirm || !mounted) return;

    final res = await deleteGroup(_group.id);
    if (!mounted) return;
    if (!res.success) {
      showSnackBar(
          context.l10n.error_deleting_group(context.errorText(res.error)),
          tone: SnackTone.failure);
      return;
    }

    // Only once the group is actually gone.
    await UserPreferences.removeFavoriteGroup(_group.id);
    if (!mounted) return;

    cacheUserGroupsForWidget();
    showSnackBar(context.l10n.group_deleted_success, tone: SnackTone.success);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  bool _canCreateInvite(String role, String permission) {
    if (role == 'owner') return true;
    if (role == 'admin') {
      return permission == 'admin' || permission == 'everyone';
    }
    if (role == 'member') return permission == 'everyone';
    return false;
  }

  String _invitePermissionLabel(BuildContext context, String permission) {
    switch (permission) {
      case 'owner':
        return context.l10n.invite_permission_owner;
      case 'everyone':
        return context.l10n.invite_permission_everyone;
      case 'admin':
      default:
        return context.l10n.invite_permission_admin;
    }
  }

  Future<void> _createInvite() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => CreateInviteDialog(groupId: _group.id),
    );
    if (token == null || !mounted) return;
    await showInviteTokenDialog(context, token);
  }

  Future<void> _changeInvitePermission() async {
    final current = _group.invitePermission ?? 'admin';
    final selected = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text(context.l10n.who_can_invite),
          children: ['owner', 'admin', 'everyone'].map((value) {
            final isSelected = value == current;
            return ListTile(
              title: Text(_invitePermissionLabel(context, value)),
              trailing: isSelected
                  ? Icon(Symbols.check_rounded,
                      color: Theme.of(context).colorScheme.primary)
                  : null,
              onTap: () => Navigator.of(context).pop(value),
            );
          }).toList(),
        );
      },
    );
    if (selected == null || selected == current || !mounted) return;

    final res = await setGroupInvitePermission(_group.id, selected);
    if (!mounted) return;
    if (res.success) {
      showSnackBar(context.l10n.invite_permission_updated,
          tone: SnackTone.success);
      setState(() => _group = _group.copyWith(invitePermission: selected));
    } else {
      showSnackBar(context.errorText(res.error), tone: SnackTone.failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SupabaseResponse<List<GroupMember>>>(
      future: _membersFuture,
      builder: (context, snapshot) {
        final hasData = snapshot.hasData;
        final members = snapshot.data?.data ?? [];
        final currentRole =
            hasData ? _getCurrentUserRole(members) : (_group.role ?? 'member');
        final isManager = currentRole == 'owner' || currentRole == 'admin';

        final permission = _group.invitePermission ?? 'admin';
        final canCreateInvite = _canCreateInvite(currentRole, permission);

        return Scaffold(
          appBar: AppBar(
            title: Text(context.l10n.group_settings_page_title),
            actions: [
              if (isManager)
                PopupMenuButton<VoidCallback>(
                  icon: const Icon(Symbols.edit_square),
                  color: Theme.of(context).colorScheme.surfaceBright,
                  position: PopupMenuPosition.under,
                  onSelected: (action) => action(),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _updateGroupName,
                      child: ListTile(
                        leading: const Icon(Icons.text_fields_rounded),
                        title: Text(context.l10n.edit_group_name),
                      ),
                    ),
                    PopupMenuItem(
                      value: openEditIconDialog,
                      child: ListTile(
                        leading: const Icon(Icons.image_rounded),
                        title: Text(context.l10n.edit_icon_title),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                /// Group Header
                Center(
                  child: Column(
                    children: [
                      GroupAvatar(_group, radius: 60),
                      const SizedBox(height: 16),
                      Text(_group.name,
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),

                Divider(
                  height: 32,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),

                /// Members List
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.members,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Symbols.info_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      tooltip: context.l10n.member_roles_title,
                      onPressed: () => showMemberRolesDialog(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                if (!hasData)
                  const Center(child: CircularProgressIndicator())
                else if (members.isEmpty)
                  Center(child: Text(context.l10n.no_members))
                else
                  Column(
                    children: members.map((member) {
                      final targetRole = member.role;
                      final canManage = member.user.id != _currentUserId &&
                          (currentRole == 'owner' ||
                              (currentRole == 'admin' &&
                                  targetRole != 'admin' &&
                                  targetRole != 'owner'));

                      return _MemberTile(
                        member: member,
                        currentRole: currentRole,
                        canManage: canManage,
                        onRoleAction: (action) =>
                            _manageUserRoleDialog(member.user.id, action),
                        onBan: () => _manageUserBanDialog(member.user.id),
                        onUnban: () => _manageUserUnbanDialog(member.user.id),
                      );
                    }).toList(),
                  ),

                /// Group invites
                if (canCreateInvite || isManager) ...[
                  Divider(
                    height: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      context.l10n.group_invites,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (canCreateInvite)
                    RectangleButton(
                      onPressed: _createInvite,
                      label: context.l10n.create_invite,
                      icon: Symbols.add_link_rounded,
                    ),
                  if (isManager) ...[
                    const SizedBox(height: 8),
                    RectangleButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => GroupInvitesPage(groupId: _group.id),
                        ),
                      ),
                      label: context.l10n.manage_invites,
                      icon: Symbols.link_rounded,
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceBright,
                    ),
                  ],
                  if (currentRole == 'owner') ...[
                    const SizedBox(height: 8),
                    ListTile(
                      leading: const Icon(Symbols.lock_person_rounded),
                      title: Text(context.l10n.who_can_invite),
                      subtitle:
                          Text(_invitePermissionLabel(context, permission)),
                      trailing: const Icon(Symbols.chevron_right_rounded),
                      onTap: _changeInvitePermission,
                    ),
                  ],
                ],

                const SizedBox(height: 8),
                SwitchListTile(
                  value: _muted,
                  onChanged: _toggleMuted,
                  secondary: Icon(_muted
                      ? Symbols.notifications_off_rounded
                      : Symbols.notifications_rounded),
                  title: Text(context.l10n.mute_notifications),
                  subtitle: Text(context.l10n.mute_notifications_subtitle),
                  contentPadding: EdgeInsets.zero,
                ),

                Divider(
                  height: 64,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),

                /// Leave/delete group buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RectangleButton(
                      onPressed: _leaveGroup,
                      label: context.l10n.leave_group,
                      icon: Symbols.logout_rounded,
                      backgroundColor: Colors.red,
                    ),
                  ],
                ),

                if (currentRole == 'owner') ...[
                  const SizedBox(height: 16),
                  RectangleButton(
                    onPressed: _deleteGroup,
                    label: context.l10n.delete_group,
                    icon: Symbols.delete_rounded,
                    backgroundColor: Colors.red,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MemberTile extends StatefulWidget {
  final GroupMember member;
  final String currentRole;
  final bool canManage;
  final void Function(String action) onRoleAction;
  final VoidCallback onBan;
  final VoidCallback onUnban;

  const _MemberTile({
    required this.member,
    required this.currentRole,
    required this.canManage,
    required this.onRoleAction,
    required this.onBan,
    required this.onUnban,
  });

  @override
  State<_MemberTile> createState() => _MemberTileState();
}

class _MemberTileState extends State<_MemberTile> {
  final _itemKey = GlobalKey();
  bool _highlighted = false;

  ({IconData? icon, Color? color}) _roleBadge(String role) {
    switch (role) {
      case 'owner':
        return (icon: Symbols.crown_rounded, color: Colors.amber);
      case 'admin':
        return (icon: Symbols.shield_person_rounded, color: Colors.blue);
      case 'banned':
        return (icon: Symbols.block_rounded, color: Colors.red);
      default:
        return (icon: null, color: null);
    }
  }

  Future<void> _showMenu() async {
    final targetRole = widget.member.role;
    final currentRole = widget.currentRole;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final box = _itemKey.currentContext?.findRenderObject() as RenderBox?;
    final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final size = box?.size ?? const Size(300, 56);

    PopupMenuItem<void> item(IconData icon, String label, VoidCallback onTap) =>
        PopupMenuItem(
          child: ListTile(
            leading: Icon(icon),
            title: Text(label),
            onTap: () {
              Navigator.pop(context);
              onTap();
            },
          ),
        );

    await showMenu<void>(
      context: context,
      color: Theme.of(context).colorScheme.surfaceBright,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(pos.dx, pos.dy + size.height, size.width, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        if (targetRole == 'member')
          item(Symbols.add_moderator_rounded, context.l10n.promote_user,
              () => widget.onRoleAction('promote_admin')),
        if (targetRole == 'admin' && currentRole == 'owner')
          item(Symbols.remove_moderator_rounded, context.l10n.demote_user,
              () => widget.onRoleAction('demote')),
        if (targetRole != 'banned' &&
            (currentRole == 'owner' ||
                (currentRole == 'admin' && targetRole == 'member')))
          item(Symbols.person_off_rounded, context.l10n.ban_user, widget.onBan),
        if (targetRole == 'banned' &&
            (currentRole == 'owner' || currentRole == 'admin'))
          item(Symbols.person_check_rounded, context.l10n.unban_user,
              widget.onUnban),
        if (currentRole == 'owner' &&
            targetRole != 'owner' &&
            targetRole != 'banned')
          item(Symbols.crown_rounded, context.l10n.transfer_ownership,
              () => widget.onRoleAction('transfer_ownership')),
      ],
    );
    if (mounted) setState(() => _highlighted = false);
  }

  @override
  Widget build(BuildContext context) {
    final badge = _roleBadge(widget.member.role);
    return GestureDetector(
      onLongPressDown:
          widget.canManage ? (_) => setState(() => _highlighted = true) : null,
      onLongPressCancel:
          widget.canManage ? () => setState(() => _highlighted = false) : null,
      onLongPress: widget.canManage ? _showMenu : null,
      child: Container(
        key: _itemKey,
        color: _highlighted ? Colors.white.withValues(alpha: 0.08) : null,
        child: ListTile(
          leading: UserAvatar(widget.member.user, radius: 25),
          title: Text(widget.member.user.username),
          trailing: Icon(badge.icon, color: badge.color, fill: 1),
        ),
      ),
    );
  }
}
