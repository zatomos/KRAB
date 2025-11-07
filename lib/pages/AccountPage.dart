import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/models/User.dart' as KRAB_User;
import 'package:krab/services/supabase.dart';
import 'package:krab/UserPreferences.dart';
import 'package:krab/widgets/RectangleButton.dart';
import 'package:krab/widgets/UserAvatar.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/RoundedInputField.dart';
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

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
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

    autoImageSave = await UserPreferences.getAutoImageSave();

    if (!userResponse.success) {
      showSnackBar(context, "Error loading user: ${userResponse.error}",
          color: Colors.red);
    }
    if (!emailResponse.success) {
      showSnackBar(context, "Error loading email: ${emailResponse.error}",
          color: Colors.red);
    }

    setState(() {
      // Update user only if data is not null
      if (userResponse.data != null) {
        user = userResponse.data!;
      }

      _usernameController.text = user.username;
      _emailController.text = emailResponse.data ?? "";
      _isLoading = false;
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
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.cancel),
            ),
            ElevatedButton(
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
              child: Text(context.l10n.save),
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
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.cancel),
            ),

            // Edit pfp
            ElevatedButton(
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
                child: Text((user.pfpUrl.isEmpty)
                    ? context.l10n.add
                    : context.l10n.edit,
                )
            ),

            // Delete pfp
            if (user.pfpUrl.isNotEmpty)
              ElevatedButton(
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
                child: Text(context.l10n.delete),
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
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
                              icon: const Icon(Icons.edit,
                                  size: 20, color: Colors.black),
                              onPressed: () {
                                openEditPfpDialog();
                              },
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
                            crossAxisAlignment: CrossAxisAlignment.center,
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
                                child: Icon(Icons.keyboard_arrow_right_rounded,
                                    size: 40,
                                    color: GlobalThemeData
                                        .darkColorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Email Field
                  AbsorbPointer(
                    child: TextField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: context.l10n.email,
                        prefixIcon: const Icon(Icons.email),
                      ),
                      readOnly: true,
                    ),
                  ),
                  const SizedBox(height: 50),

                  // Settings Section
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
                    onChanged: (bool value) {
                      UserPreferences.setAutoImageSave(value);
                      setState(() {
                        autoImageSave = value;
                      });
                    },
                  ),

                  const SizedBox(height: 80),

                  // Logout Button
                  RectangleButton(
                    label: context.l10n.log_out,
                    onPressed: _logout,
                    backgroundColor: Colors.redAccent,
                  ),
                ],
              ),
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
