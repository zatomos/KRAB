import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/widgets/group_avatar.dart';
import 'package:krab/widgets/user_avatar.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/group_member.dart';
import 'package:krab/services/supabase.dart';
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
              SoftButton(
                onPressed: () async {
                  final newName = controller.text.trim();
                  if (newName.isEmpty) {
                    setDialogState(() {
                      error = true;
                      errorMessage = context.l10n.group_name_empty;
                    });
                    return;
                  }

                  final response = await updateGroupName(_group.id, newName);
                  if (!context.mounted || !mounted) return;

                  if (!response.success) {
                    setDialogState(() {
                      error = true;
                      errorMessage = response.error.toString();
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
    await showDialog(
      context: context,
      builder: (dialogContext) {
        final title = {
          "promote_admin": dialogContext.l10n.promote_user,
          "demote": dialogContext.l10n.demote_user,
          "transfer_ownership": dialogContext.l10n.transfer_ownership,
        }[action]!;

        final content = {
          "promote_admin": dialogContext.l10n.promote_user_confirmation,
          "demote": dialogContext.l10n.demote_user_confirmation,
          "transfer_ownership":
              dialogContext.l10n.transfer_ownership_confirmation,
        }[action]!;

        return AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: dialogContext.l10n.cancel,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),
            SoftButton(
              onPressed: () async {
                final l10n = dialogContext.l10n;
                Navigator.of(dialogContext).pop();

                final res = await changeMemberRole(_group.id, userId, action);
                if (!mounted) return;

                if (res.success) {
                  showSnackBar(l10n.user_role_updated_success,
                      color: Colors.green);
                  setState(() {
                    _membersFuture = getGroupMembers(_group.id);
                  });
                } else {
                  showSnackBar(
                    l10n.error_updating_user_role(res.error ?? "Unknown"),
                    color: Colors.red,
                  );
                }
              },
              label: dialogContext.l10n.confirm,
              color: GlobalThemeData.darkColorScheme.primary,
            ),
          ],
        );
      },
    );
  }

  Future<void> _manageUserBanDialog(String userId) async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.ban_user),
          content: Text(context.l10n.ban_user_confirmation),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(context).pop(),
              label: context.l10n.cancel,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),
            SoftButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _banUser(userId);
              },
              label: context.l10n.confirm,
              color: GlobalThemeData.darkColorScheme.primary,
            ),
          ],
        );
      },
    );
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
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.unban_user),
          content: Text(context.l10n.unban_user_confirmation),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(context).pop(),
              label: context.l10n.cancel,
            ),
            SoftButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _unbanUser(userId);
              },
              label: context.l10n.confirm,
              color: GlobalThemeData.darkColorScheme.primary,
            ),
          ],
        );
      },
    );
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
    final confirm = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(context.l10n.delete_group),
              content: Text(context.l10n.delete_group_confirmation),
              actions: [
                SoftButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  label: context.l10n.cancel,
                  color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
                ),
                SoftButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  label: context.l10n.delete,
                  color: Colors.red,
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirm) return;
    if (!mounted) return;

    await UserPreferences.removeFavoriteGroup(_group.id);

    final res = await deleteGroup(_group.id);
    if (!mounted) return;
    if (!res.success) {
      showSnackBar(context.l10n.error_deleting_group(res.error ?? "Unknown"),
          color: Colors.red);
      return;
    }

    showSnackBar(context.l10n.group_deleted_success, color: Colors.green);
    Navigator.of(context).popUntil((r) => r.isFirst);
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

                final currentRole =
                    members.firstWhere((m) => m.user.id == _currentUserId).role;

                return Column(
                  children: members.map((member) {
                    final targetRole = member.role;
                    Offset? tapPos;

                    return GestureDetector(
                      onLongPressDown: (details) {
                        tapPos = details.globalPosition;
                      },
                      onLongPress: () {
                        final isAdmin =
                            currentRole == 'owner' || currentRole == 'admin';

                        if (!isAdmin ||
                            member.user.id == _currentUserId ||
                            tapPos == null) {
                          return;
                        }

                        final overlay = Overlay.of(context)
                            .context
                            .findRenderObject() as RenderBox;

                        showMenu(
                          context: context,
                          color: GlobalThemeData.darkColorScheme.surfaceBright,
                          position: RelativeRect.fromRect(
                            Rect.fromLTWH(tapPos!.dx, tapPos!.dy, 0, 0),
                            Offset.zero & overlay.size,
                          ),
                          items: [
                            if (targetRole == 'member')
                              PopupMenuItem(
                                child: ListTile(
                                  leading:
                                      const Icon(Symbols.add_moderator_rounded),
                                  title: Text(context.l10n.promote_user),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _manageUserRoleDialog(
                                        member.user.id, 'promote_admin');
                                  },
                                ),
                              ),
                            if (targetRole == 'admin')
                              PopupMenuItem(
                                child: ListTile(
                                  leading: const Icon(
                                      Symbols.remove_moderator_rounded),
                                  title: Text(context.l10n.demote_user),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _manageUserRoleDialog(
                                        member.user.id, 'demote');
                                  },
                                ),
                              ),
                            if ((targetRole != 'banned') &&
                                ((currentRole == 'owner') ||
                                    (currentRole == 'admin' &&
                                        targetRole == 'member')))
                              PopupMenuItem(
                                child: ListTile(
                                  leading:
                                      const Icon(Symbols.person_off_rounded),
                                  title: Text(context.l10n.ban_user),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _manageUserBanDialog(member.user.id);
                                  },
                                ),
                              ),
                            if ((targetRole == 'banned') &&
                                (currentRole == 'owner' ||
                                    currentRole == 'admin'))
                              PopupMenuItem(
                                child: ListTile(
                                  leading:
                                      const Icon(Symbols.person_check_rounded),
                                  title: Text(context.l10n.unban_user),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _manageUserUnbanDialog(member.user.id);
                                  },
                                ),
                              ),
                            if (currentRole == 'owner' &&
                                targetRole != 'owner' &&
                                targetRole != 'banned')
                              PopupMenuItem(
                                child: ListTile(
                                  leading: const Icon(Symbols.crown_rounded),
                                  title: Text(context.l10n.transfer_ownership),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _manageUserRoleDialog(
                                        member.user.id, 'transfer_ownership');
                                  },
                                ),
                              ),
                          ],
                        );
                      },
                      child: ListTile(
                        leading: UserAvatar(member.user, radius: 25),
                        title: Text(member.user.username),
                        trailing: Icon(
                            targetRole == 'owner'
                                ? Symbols.crown_rounded
                                : targetRole == 'admin'
                                    ? Symbols.shield_person_rounded
                                    : targetRole == 'banned'
                                        ? Symbols.block_rounded
                                        : null,
                            color: targetRole == 'owner'
                                ? Colors.amber
                                : targetRole == 'admin'
                                    ? Colors.blue
                                    : targetRole == 'banned'
                                        ? Colors.red
                                        : null,
                            fill: 1),
                      ),
                    );
                  }).toList(),
                );
              },
            ),

            /// Group Invite Code
            if (_group.code != null) ...[
              Divider(
                height: 64,
                color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
              ),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(
                      ClipboardData(text: _group.code!.toUpperCase()));
                  showSnackBar(context.l10n.group_code_copied,
                      color: Colors.green);
                },
                child: Text(
                  context.l10n.group_code(_group.code!.toUpperCase()),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],

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
