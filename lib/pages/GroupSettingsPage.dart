import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_bar_code/qr/src/qr_code.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:krab/widgets/GroupAvatar.dart';
import 'package:krab/widgets/UserAvatar.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/RectangleButton.dart';
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/models/Group.dart';
import 'package:krab/models/User.dart' as KrabUser;
import 'package:krab/services/supabase.dart';
import 'package:krab/UserPreferences.dart';
import '../themes/GlobalThemeData.dart';

class GroupSettingsPage extends StatefulWidget {
  final Group group;
  final bool isAdmin;

  const GroupSettingsPage({
    super.key,
    required this.group,
    this.isAdmin = false,
  });

  @override
  GroupSettingsPageState createState() => GroupSettingsPageState();
}

class GroupSettingsPageState extends State<GroupSettingsPage> {
  late Group _group;
  late Future<SupabaseResponse<List<KrabUser.User>>> _membersFuture;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _membersFuture = getGroupMembers(_group.id);
  }

  Future<void> _leaveGroup() async {
    await UserPreferences.removeFavoriteGroup(_group.id);
    final response = await leaveGroup(_group.id);
    if (response.success) {
      showSnackBar(context, context.l10n.left_group_success, color: Colors.green);
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      showSnackBar(
        context,
        context.l10n.error_leaving_group(response.error ?? "Unknown error"),
        color: Colors.red,
      );
    }
  }

  Future<void> _updateGroupName() async {
    TextEditingController controller = TextEditingController(text: _group.name);
    bool error = false;
    String errorMessage = "";

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
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
                      child: Text(
                        errorMessage,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.cancel),
                ),
                TextButton(
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
                    if (!response.success) {
                      setDialogState(() {
                        error = true;
                        errorMessage = context.l10n.error_updating_group_name(
                          response.error.toString(),
                        );
                      });
                    } else {
                      Navigator.of(context).pop();
                      showSnackBar(context, context.l10n.group_name_updated_success,
                          color: Colors.green);
                      setState(() {
                        _group = _group.copyWith(name: newName);
                      });
                    }
                  },
                  child: Text(context.l10n.save),
                ),
              ],
            );
          },
        );
      },
    );
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

  Future<void> openEditIconDialog() async {
    await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.edit_icon_title),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.cancel),
            ),

            // Add/Edit icon
            ElevatedButton(
              onPressed: () {
                pickCropPfp().then((file) async {
                  if (file == null) return;

                  final successMsg = context.l10n.icon_updated_success;
                  final errorMsg = context.l10n.error_updating_icon;

                  Navigator.of(context).pop();

                  final response = await editGroupIcon(file, _group.id);
                  if (response.success) {
                    // Refresh signed URL
                    final newUrlResponse = await getGroupIconUrl(_group.id);
                    if (newUrlResponse.success) {
                      setState(() {
                        _group = _group.copyWith(iconUrl: newUrlResponse.data);
                      });
                    }
                    showSnackBar(null, successMsg, color: Colors.green);
                  } else {
                    showSnackBar(null, "$errorMsg: ${response.error}",
                        color: Colors.red);
                  }
                });
              },
              child: Text(
                (_group.iconUrl == null || _group.iconUrl!.isEmpty)
                    ? context.l10n.add
                    : context.l10n.edit,
              ),
            ),

            // Delete icon
            if (_group.iconUrl != null && _group.iconUrl!.isNotEmpty)
              ElevatedButton(
                onPressed: () async {
                  final response = await deleteGroupIcon(_group.id);

                  final successMsg = context.l10n.icon_deleted_success;
                  final errorMsg = context.l10n.error_deleting_icon;

                  Navigator.of(context).pop();

                  if (response.success) {
                    setState(() {
                      _group = _group.copyWith(iconUrl: '');
                    });
                    showSnackBar(null, successMsg, color: Colors.green);
                  } else {
                    showSnackBar(null, "$errorMsg: ${response.error}",
                        color: Colors.red);
                  }
                },
                child: Text(context.l10n.delete),
              ),
          ],
        );
      },
    );
  }

  Future<void> _deleteGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.delete_group),
          content: Text(context.l10n.delete_group_confirmation),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.l10n.cancel)),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(context.l10n.delete)),
          ],
        );
      },
    ) ??
        false;

    if (!confirm) return;

    await UserPreferences.removeFavoriteGroup(_group.id);
    final response = await deleteGroup(_group.id);
    if (response.success) {
      showSnackBar(context, context.l10n.group_deleted_success, color: Colors.green);
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      showSnackBar(
        context,
        context.l10n.error_deleting_group(response.error ?? "Unknown error"),
        color: Colors.red,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.group_settings_page_title), actions: [
        if (widget.isAdmin)
          IconButton(
            icon: const Icon(Icons.edit),
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
          ),
      ]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  GroupAvatar(_group, radius: 60),
                  const SizedBox(height: 16),
                  Text(
                    _group.name,
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            Divider(height: 32, color: GlobalThemeData.darkColorScheme.onSurfaceVariant),

            // Members section
            Text(
              context.l10n.members,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            FutureBuilder<SupabaseResponse<List<KrabUser.User>>>(
              future: _membersFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text("Error: ${snapshot.error}"));
                }

                final response = snapshot.data;
                if (response == null || response.data == null) {
                  return Center(child: Text(context.l10n.error_loading_members));
                }

                final members = response.data!;
                if (members.isEmpty) {
                  return Center(child: Text(context.l10n.no_members));
                }

                return Column(
                  children: members.map((user) {
                    return ListTile(
                      leading: UserAvatar(user, radius: 25),
                      title: Text(user.username),
                    );
                  }).toList(),
                );
              },
            ),

            if (_group.code != null) ...[
              Divider(height: 64, color: GlobalThemeData.darkColorScheme.onSurfaceVariant),
              Center(
                child: Column(children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: QRCode(
                      data: _group.code!.toUpperCase(),
                      size: MediaQuery.of(context).size.width * 0.3,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.group_code(_group.code!.toUpperCase()),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ]),
              ),
            ],

            Divider(height: 64, color: GlobalThemeData.darkColorScheme.onSurfaceVariant),
            Center(
              child: Column(
                children: [
                  RectangleButton(
                    onPressed: _leaveGroup,
                    label: context.l10n.leave_group,
                    backgroundColor: Colors.red,
                  ),
                  if (widget.isAdmin) const SizedBox(height: 16),
                  if (widget.isAdmin)
                    RectangleButton(
                      onPressed: _deleteGroup,
                      label: context.l10n.delete_group,
                      backgroundColor: Colors.red,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}