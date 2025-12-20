import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/models/User.dart' as KRAB_User;
import 'package:krab/services/supabase.dart';
import 'package:krab/UserPreferences.dart';
import 'package:krab/widgets/RectangleButton.dart';
import 'package:krab/widgets/UserAvatar.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/widgets/SoftButton.dart';
import 'LoginPage.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  AccountPageState createState() => AccountPageState();
}

class AccountPageState extends State<AccountPage> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();

  KRAB_User.User user = const KRAB_User.User(id: '', username: '');
  bool _isLoading = false;

  bool autoImageSave = false;
  bool receiveAllGroupComments = false;

  String appVersion = "";

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _loadAppVersion();
  }

  Future<void> _loadUserProfile() async {
    setState(() {
      _isLoading = true;
    });

    final supabase = Supabase.instance.client;
    final authUser = supabase.auth.currentUser;

    if (authUser == null) {
      setState(() {
        _isLoading = false;
      });
      showSnackBar(context, "No user logged in.", color: Colors.red);
      return;
    }

    final userResponse = await getUserDetails(authUser.id);
    final emailResponse = await getEmail();

    // Check auto image save preference
    autoImageSave = await UserPreferences.getAutoImageSave();

    if (!userResponse.success) {
      showSnackBar(context, "Error loading user: ${userResponse.error}",
          color: Colors.red);
    }
    if (!emailResponse.success) {
      showSnackBar(context, "Error loading email: ${emailResponse.error}",
          color: Colors.red);
    }

    // Load group comment notification setting
    final groupCommentSettingResponse =
        await getGroupCommentNotificationSetting();

    if (!groupCommentSettingResponse.success) {
      showSnackBar(
        context,
        "Error loading notification setting: ${groupCommentSettingResponse.error}",
        color: Colors.red,
      );
    }

    setState(() {
      // Update user only if data is not null
      if (userResponse.data != null) {
        user = userResponse.data!;
      }

      _usernameController.text = user.username;
      _emailController.text = emailResponse.data ?? "";

      if (groupCommentSettingResponse.success &&
          groupCommentSettingResponse.data != null) {
        receiveAllGroupComments = groupCommentSettingResponse.data!;
      }

      _isLoading = false;
    });
  }

  Future<void> _loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      appVersion = packageInfo.version;
    });
  }

  Future<void> _logout() async {
    await logOut();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  Future<void> openEditUsernameDialog() async {
    _usernameController.text = user.username;

    await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.edit_username),
          content: RoundedInputField(
              controller: _usernameController, hintText: context.l10n.username),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(context).pop(),
              label: context.l10n.cancel,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),
            SoftButton(
              onPressed: () {
                final response = editUsername(_usernameController.text);
                Navigator.of(context).pop(_usernameController.text);

                response.then((res) {
                  if (res.success) {
                    setState(() {
                      user = user.copyWith(username: _usernameController.text);
                    });
                    showSnackBar(context, context.l10n.username_updated_success,
                        color: Colors.green);
                  } else {
                    showSnackBar(context,
                        "${context.l10n.error_updating_username}: ${res.error}",
                        color: Colors.red);
                  }
                });
              },
              label: context.l10n.save,
              color: GlobalThemeData.darkColorScheme.primary,
            ),
          ],
        );
      },
    );
  }

  Future<void> openEditPfpDialog() async {
    await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.edit_pfp_title),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(context).pop(),
              label: context.l10n.cancel,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),

            // Edit pfp
            SoftButton(
                onPressed: () {
                  pickCropPfp().then((file) {
                    if (file != null) {
                      // Cache localization
                      final successMsg = context.l10n.pfp_updated_success;
                      final errorMsg = context.l10n.error_updating_pfp;

                      // Upload new profile picture
                      final response = editProfilePicture(file);

                      // Close dialog
                      Navigator.of(context).pop();

                      response.then((res) async {
                        if (!mounted) return;

                        if (res.success) {
                          // Get a fresh signed URL
                          final newUrlResponse =
                              await getProfilePictureUrl(user.id);
                          String? newUrl;
                          if (newUrlResponse.success) {
                            newUrl = newUrlResponse.data;
                          }

                          // Update user state
                          if (!mounted) return;
                          setState(() {
                            user = user.copyWith(pfpUrl: newUrl);
                          });

                          // Show success snackbar
                          showSnackBar(null, successMsg, color: Colors.green);
                        } else {
                          showSnackBar(null, "$errorMsg: ${res.error}",
                              color: Colors.red);
                        }
                      });
                    }
                  });
                },
                label: (user.pfpUrl.isEmpty)
                    ? context.l10n.add
                    : context.l10n.edit,
                color: GlobalThemeData.darkColorScheme.primary),

            // Delete pfp
            if (user.pfpUrl.isNotEmpty)
              SoftButton(
                onPressed: () {
                  // Delete profile picture from DB
                  final response = deleteProfilePicture();

                  // Cache localization
                  final successMsg = context.l10n.pfp_deleted_success;
                  final errorMsg = context.l10n.error_deleting_pfp;
                  Navigator.of(context).pop();

                  // Handle response
                  response.then((res) {
                    if (!mounted) return;

                    if (res.success) {
                      setState(() => user = user.copyWith(pfpUrl: null));
                      showSnackBar(null, successMsg, color: Colors.green);
                    } else {
                      showSnackBar(null, "$errorMsg: ${res.error}",
                          color: Colors.red);
                    }
                  });
                },
                label: context.l10n.delete,
                color: Colors.redAccent,
              )
          ],
        );
      },
    );
  }

  Future<File?> pickCropPfp() async {
    final pfpPicked =
        await ImagePicker().pickImage(source: ImageSource.gallery);
    if (pfpPicked == null) return null;

    final pfpCropped = await ImageCropper().cropImage(
      sourcePath: pfpPicked.path,
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

    if (pfpCropped == null) return null;
    return File(pfpCropped.path);
  }

  @override
  Scaffold build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.account_page_title)),
      body: Column(
        children: [
          // Scrollable content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Stack(
                      children: [
                        UserAvatar(user, radius: 60),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.white,
                            child: IconButton(
                              icon: const Icon(
                                Symbols.edit_rounded,
                                size: 20,
                                color: Colors.black,
                              ),
                              onPressed: openEditPfpDialog,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  GestureDetector(
                    onTap: openEditUsernameDialog,
                    child: Stack(
                      children: [
                        Center(
                          child: Text(
                            user.username,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Opacity(
                                opacity: 0,
                                child: Text(
                                  user.username,
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Transform.translate(
                                offset: const Offset(20, -2),
                                child: Icon(
                                  Icons.keyboard_arrow_right_rounded,
                                  size: 40,
                                  color: GlobalThemeData
                                      .darkColorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  AbsorbPointer(
                    child: TextField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: context.l10n.email,
                        prefixIcon: const Icon(Symbols.email_rounded, fill: 1),
                      ),
                      readOnly: true,
                    ),
                  ),
                  const SizedBox(height: 35),
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Text(
                      context.l10n.settings,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    title: Text(context.l10n.auto_save_imgs),
                    subtitle: Text(context.l10n.auto_save_imgs_description),
                    value: autoImageSave,
                    onChanged: (value) {
                      UserPreferences.setAutoImageSave(value);
                      setState(() => autoImageSave = value);
                    },
                  ),
                  SwitchListTile(
                    title: Text(context.l10n.group_comment_notifications),
                    subtitle: Text(
                        context.l10n.group_comment_notifications_description),
                    value: receiveAllGroupComments,
                    onChanged: (value) {
                      final response =
                          setGroupCommentNotificationSetting(value);
                      response.then((res) {
                        if (res.success) {
                          setState(() => receiveAllGroupComments = value);
                        } else {
                          showSnackBar(
                              context, "Error updating setting: ${res.error}",
                              color: Colors.red);
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 40),
                  RectangleButton(
                    label: context.l10n.log_out,
                    onPressed: _logout,
                    backgroundColor: Colors.redAccent,
                  ),
                ],
              ),
            ),
          ),

          // Bottom text stays here if possible
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'KRAB v$appVersion',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    super.dispose();
  }
}
