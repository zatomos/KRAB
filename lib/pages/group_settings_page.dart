import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/group_member.dart';
import 'package:krab/pages/group_invites_page.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/themes/global_theme_data.dart';
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

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _membersFuture = getGroupMembers(_group.id);
    _currentUserId = Supabase.instance.client.auth.currentUser?.id;
  }

  String _getCurrentUserRole(List<GroupMember> members) {
    if (_currentUserId == null) return 'member';

    final me = members.firstWhere(
      (m) => m.user.id == _currentUserId,
      orElse: () => GroupMember.empty(),
    );

    return me.role;
  }

  Future<File?> pickCropPfp() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return null;

    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      maxHeight: 1000,
      maxWidth: 1000,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Image',
          toolbarColor: GlobalThemeData.darkColorScheme.surface,
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: GlobalThemeData.darkColorScheme.primary,
          statusBarLight: false,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
        ),
      ],
    );

    if (cropped == null) return null;
    return File(cropped.path);
  }

  Future<void> _leaveGroup() async {
    await UserPreferences.removeFavoriteGroup(widget.group.id);
    final response = await leaveGroup(widget.group.id);
    if (!mounted) return;
    if (response.success) {
      cacheUserGroupsForWidget();
      showSnackBar(context.l10n.left_group_success, color: Colors.green);
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      showSnackBar(
          context.l10n.error_leaving_group(response.error ?? "Unknown error"),
          color: Colors.red);
    }
  }

  Future<void> _updateGroupName() async {
    TextEditingController controller = TextEditingController(text: _group.name);
    bool error = false;
    String errorMessage = "";
    bool saving = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(context.l10n.edit_group_name),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RoundedInputField(
                  controller: controller,
                  hintText: context.l10n.new_group_name,
                ),
                if (error)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(errorMessage,
                        style: const TextStyle(color: Colors.red)),
                  ),
              ],
            ),
            actions: [
              SoftButton(
                onPressed: () => Navigator.of(context).pop(),
                label: context.l10n.cancel,
                color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
              ),
              if (saving)
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                SoftButton(
                  onPressed: () async {
                    if (saving) return;
                    final newName = controller.text.trim();
                    if (newName.isEmpty) {
                      setDialogState(() {
                        error = true;
                        errorMessage = context.l10n.group_name_empty;
                      });
                      return;
                    }
                    setDialogState(() => saving = true);

                    final response = await updateGroupName(_group.id, newName);
                    if (!context.mounted || !mounted) return;

                    if (!response.success) {
                      setDialogState(() {
                        error = true;
                        errorMessage = response.error.toString();
                        saving = false;
                      });
                      return;
                    }

                    Navigator.of(context).pop();
                    showSnackBar(context.l10n.group_name_updated_success,
                        color: Colors.green);
                    setState(() {
                      _group = _group.copyWith(name: newName);
                    });
                  },
                  label: context.l10n.save,
                  color: GlobalThemeData.darkColorScheme.primary,
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> openEditIconDialog() async {
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n.edit_icon_title),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: dialogContext.l10n.cancel,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),

            // Add / edit icon
            SoftButton(
              onPressed: () {
                pickCropPfp().then((file) async {
                  if (file == null) return;
                  if (!dialogContext.mounted) return;
                  final l10n = dialogContext.l10n;

                  Navigator.of(dialogContext).pop();

                  final res = await editGroupIcon(file, _group.id);
                  if (!mounted) return;
                  if (!res.success) {
                    showSnackBar(
                        l10n.error_updating_icon(res.error ?? "Unknown"),
                        color: Colors.red);
                    return;
                  }

                  final newUrl = await getGroupIconUrl(_group.id);
                  if (newUrl.success) {
                    setState(() {
                      _group = _group.copyWith(iconUrl: newUrl.data);
                    });
                  }

                  showSnackBar(l10n.icon_updated_success, color: Colors.green);
                });
              },
              label: (_group.iconUrl?.isEmpty ?? true)
                  ? dialogContext.l10n.add
                  : dialogContext.l10n.edit,
              color: GlobalThemeData.darkColorScheme.primary,
            ),

            // Delete icon
            if (_group.iconUrl != null && _group.iconUrl!.isNotEmpty)
              SoftButton(
                onPressed: () async {
                  final l10n = dialogContext.l10n;
                  Navigator.of(dialogContext).pop();

                  final res = await deleteGroupIcon(_group.id);
                  if (!mounted) return;
                  if (!res.success) {
                    showSnackBar(
                        l10n.error_deleting_icon(res.error ?? "Unknown"),
                        color: Colors.red);
                    return;
                  }

                  setState(() {
                    _group = _group.copyWith(iconUrl: '');
                  });

                  showSnackBar(l10n.icon_deleted_success, color: Colors.green);
                },
                label: dialogContext.l10n.delete,
                color: Colors.red,
              ),
          ],
        );
      },
    );
  }

  Future<void> _manageUserRoleDialog(String userId, String action) async {
    final title = {
      "promote_admin": context.l10n.promote_user,
      "demote": context.l10n.demote_user,
      "transfer_ownership": context.l10n.transfer_ownership,
    }[action]!;
    final content = {
      "promote_admin": context.l10n.promote_user_confirmation,
      "demote": context.l10n.demote_user_confirmation,
      "transfer_ownership": context.l10n.transfer_ownership_confirmation,
    }[action]!;

    final confirmed = await showConfirmDialog(context,
        title: title, message: content, confirmLabel: context.l10n.confirm);
    if (!confirmed || !mounted) return;

    final res = await changeMemberRole(_group.id, userId, action);
    if (!mounted) return;
    if (res.success) {
      showSnackBar(context.l10n.user_role_updated_success, color: Colors.green);
      setState(() => _membersFuture = getGroupMembers(_group.id));
    } else {
      showSnackBar(
        context.l10n.error_updating_user_role(res.error ?? "Unknown"),
        color: Colors.red,
      );
    }
  }

  Future<void> _manageUserBanDialog(String userId) async {
    final confirmed = await showConfirmDialog(context,
        title: context.l10n.ban_user,
        message: context.l10n.ban_user_confirmation,
        confirmLabel: context.l10n.confirm);
    if (!confirmed) return;
    await _banUser(userId);
  }

  Future<void> _banUser(String userId) async {
    final res = await banUser(widget.group.id, userId);
    if (!mounted) return;
    if (res.success) {
      showSnackBar(context.l10n.user_banned_success, color: Colors.green);
      setState(() => _membersFuture = getGroupMembers(widget.group.id));
    } else {
      showSnackBar(context.l10n.error_banning_user(res.error ?? "Unknown"),
          color: Colors.red);
    }
  }

  Future<void> _manageUserUnbanDialog(String userId) async {
    final confirmed = await showConfirmDialog(context,
        title: context.l10n.unban_user,
        message: context.l10n.unban_user_confirmation,
        confirmLabel: context.l10n.confirm);
    if (!confirmed) return;
    await _unbanUser(userId);
  }

  Future<void> _unbanUser(String userId) async {
    final res = await unbanUser(widget.group.id, userId);
    if (!mounted) return;
    if (res.success) {
      showSnackBar("User unbanned", color: Colors.green);
      setState(() => _membersFuture = getGroupMembers(widget.group.id));
    } else {
      showSnackBar("Error: ${res.error}", color: Colors.red);
    }
  }

  Future<void> _deleteGroup() async {
    final confirm = await showConfirmDialog(context,
        title: context.l10n.delete_group,
        message: context.l10n.delete_group_confirmation,
        confirmLabel: context.l10n.delete,
        destructive: true);
    if (!confirm || !mounted) return;

    await UserPreferences.removeFavoriteGroup(_group.id);

    final res = await deleteGroup(_group.id);
    if (!mounted) return;
    if (!res.success) {
      showSnackBar(context.l10n.error_deleting_group(res.error ?? "Unknown"),
          color: Colors.red);
      return;
    }

    cacheUserGroupsForWidget();
    showSnackBar(context.l10n.group_deleted_success, color: Colors.green);
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
                      color: GlobalThemeData.darkColorScheme.primary)
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
      showSnackBar(context.l10n.invite_permission_updated, color: Colors.green);
      setState(() => _group = _group.copyWith(invitePermission: selected));
    } else {
      showSnackBar(res.error ?? "Unknown error", color: Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.group_settings_page_title),
        actions: [
          FutureBuilder<SupabaseResponse<List<GroupMember>>>(
            future: _membersFuture,
            builder: (context, snapshot) {
              final members = snapshot.data?.data ?? [];
              final currentRole =
                  snapshot.hasData ? _getCurrentUserRole(members) : 'member';

              if (currentRole != 'admin' && currentRole != 'owner') {
                return const SizedBox.shrink();
              }

              return IconButton(
                icon: const Icon(Symbols.edit_square),
                onPressed: () {
                  showMenu(
                    context: context,
                    color: GlobalThemeData.darkColorScheme.surfaceBright,
                    position: const RelativeRect.fromLTRB(0, 90, -1, 0),
                    items: [
                      PopupMenuItem(
                        child: ListTile(
                          leading: const Icon(Icons.text_fields_rounded),
                          title: Text(context.l10n.edit_group_name),
                          onTap: () {
                            Navigator.pop(context);
                            _updateGroupName();
                          },
                        ),
                      ),
                      PopupMenuItem(
                        child: ListTile(
                          leading: const Icon(Icons.image_rounded),
                          title: Text(context.l10n.edit_icon_title),
                          onTap: () {
                            Navigator.pop(context);
                            openEditIconDialog();
                          },
                        ),
                      ),
                    ],
                  );
                },
              );
            },
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
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),

            /// Members List
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.l10n.members,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),

            FutureBuilder<SupabaseResponse<List<GroupMember>>>(
              future: _membersFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final members = snapshot.data!.data ?? [];
                if (members.isEmpty) {
                  return Center(child: Text(context.l10n.no_members));
                }

                final currentRole = members
                    .firstWhere((m) => m.user.id == _currentUserId,
                        orElse: () => GroupMember.empty())
                    .role;

                return Column(
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
                );
              },
            ),

            /// Group invites
            FutureBuilder<SupabaseResponse<List<GroupMember>>>(
              future: _membersFuture,
              builder: (context, snapshot) {
                final members = snapshot.data?.data ?? [];
                final role = snapshot.hasData
                    ? _getCurrentUserRole(members)
                    : (_group.role ?? 'member');
                final permission = _group.invitePermission ?? 'admin';
                final canCreate = _canCreateInvite(role, permission);
                final isManager = role == 'owner' || role == 'admin';

                if (!canCreate && !isManager) {
                  return const SizedBox.shrink();
                }

                return Column(
                  children: [
                    Divider(
                      height: 64,
                      color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
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
                    if (canCreate)
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
                            builder: (_) =>
                                GroupInvitesPage(groupId: _group.id),
                          ),
                        ),
                        label: context.l10n.manage_invites,
                        icon: Symbols.link_rounded,
                        backgroundColor:
                            GlobalThemeData.darkColorScheme.surfaceBright,
                      ),
                    ],
                    if (role == 'owner') ...[
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
                );
              },
            ),

            Divider(
              height: 64,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
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

            FutureBuilder<SupabaseResponse<List<GroupMember>>>(
              future: _membersFuture,
              builder: (context, snapshot) {
                final members = snapshot.data?.data ?? [];
                final currentRole =
                    snapshot.hasData ? _getCurrentUserRole(members) : 'member';

                if (currentRole != 'owner') {
                  return const SizedBox.shrink();
                }

                return Column(
                  children: [
                    const SizedBox(height: 16),
                    RectangleButton(
                      onPressed: _deleteGroup,
                      label: context.l10n.delete_group,
                      icon: Symbols.delete_rounded,
                      backgroundColor: Colors.red,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
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
      color: GlobalThemeData.darkColorScheme.surfaceBright,
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
