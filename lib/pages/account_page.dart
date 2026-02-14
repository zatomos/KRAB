import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/supabase.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/user_avatar.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/update_dialog.dart';
import 'login_page.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  AccountPageState createState() => AccountPageState();
}

class AccountPageState extends State<AccountPage> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _updateService = UpdateService();

  krab_user.User user = const krab_user.User(id: '', username: '');
  bool _isLoading = false;

  bool autoImageSave = false;
  bool receiveAllGroupComments = false;
  bool debugNotificationsEnabled = false;
  bool _isCheckingForUpdates = false;
  bool _developerOptionsUnlocked = false;
  int _pfpTapCount = 0;

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
      showSnackBar("No user logged in.", color: Colors.red);
      return;
    }

    final userResponse = await getUserDetails(authUser.id);
    final emailResponse = await getEmail();

    // Check auto image save preference
    autoImageSave = await UserPreferences.getAutoImageSave();

    // Check debug notifications preference
    debugNotificationsEnabled = await UserPreferences.getDebugNotifications();
    _developerOptionsUnlocked =
        await UserPreferences.getDeveloperOptionsUnlocked();
    if (!mounted) return;

    if (!userResponse.success) {
      showSnackBar("Error loading user: ${userResponse.error}",
          color: Colors.red);
    }
    if (!emailResponse.success) {
      showSnackBar("Error loading email: ${emailResponse.error}",
          color: Colors.red);
    }

    // Load group comment notification setting
    final groupCommentSettingResponse =
        await getGroupCommentNotificationSetting();
    if (!mounted) return;

    if (!groupCommentSettingResponse.success) {
      showSnackBar(
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
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  Future<void> _checkForUpdates() async {
    if (_isCheckingForUpdates) return;

    setState(() => _isCheckingForUpdates = true);
    final result = await _updateService.checkForUpdate(requireEnabled: false);
    if (!mounted) return;
    setState(() => _isCheckingForUpdates = false);

    if (!result.success) {
      showSnackBar(
        context.l10n.update_check_failed,
      );
      return;
    }

    if (result.hasUpdate && result.info != null) {
      await showUpdateDialog(
        context: context,
        updateService: _updateService,
        info: result.info!,
        currentVersion: appVersion.isEmpty ? null : appVersion,
      );
      return;
    }

    showSnackBar(context.l10n.no_update_available, color: Colors.green);
  }

  Future<void> _handlePfpTap() async {
    _pfpTapCount++;
    debugPrint("PFP tapped $_pfpTapCount times");
    if (_pfpTapCount < 10) return;

    final nextValue = !_developerOptionsUnlocked;
    await UserPreferences.setDeveloperOptionsUnlocked(nextValue);
    if (!mounted) return;

    setState(() {
      _developerOptionsUnlocked = nextValue;
      _pfpTapCount = 0;
    });
    if (nextValue) {
      showSnackBar('Developer options unlocked', color: Colors.green);
    } else {
      debugNotificationsEnabled = false;
      showSnackBar('Developer options hidden');
    }
  }

  Future<void> openEditUsernameDialog() async {
    _usernameController.text = user.username;

    await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n.edit_username),
          content: RoundedInputField(
              controller: _usernameController,
              hintText: dialogContext.l10n.username),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: dialogContext.l10n.cancel,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),
            SoftButton(
              onPressed: () {
                final successMsg = dialogContext.l10n.username_updated_success;
                final errorPrefix = dialogContext.l10n.error_updating_username;
                final response = editUsername(_usernameController.text);
                Navigator.of(dialogContext).pop(_usernameController.text);

                response.then((res) {
                  if (!mounted) return;
                  if (res.success) {
                    setState(() {
                      user = user.copyWith(username: _usernameController.text);
                    });
                    showSnackBar(successMsg, color: Colors.green);
                  } else {
                    showSnackBar("$errorPrefix: ${res.error}",
                        color: Colors.red);
                  }
                });
              },
              label: dialogContext.l10n.save,
              color: GlobalThemeData.darkColorScheme.primary,
            ),
          ],
        );
      },
    );
  }

  Future<void> openEditPfpDialog() async {
    final pageContext = context;
    await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n.edit_pfp_title),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: dialogContext.l10n.cancel,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),

            // Edit pfp
            SoftButton(
                onPressed: () {
                  pickCropPfp().then((file) {
                    if (!mounted || !dialogContext.mounted) return;
                    if (file != null) {
                      // Cache localization
                      final successMsg = pageContext.l10n.pfp_updated_success;
                      final errorMsg = pageContext.l10n.error_updating_pfp;

                      // Upload new profile picture
                      final response = editProfilePicture(file);

                      // Close dialog
                      Navigator.of(dialogContext).pop();

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
                          showSnackBar(successMsg, color: Colors.green);
                        } else {
                          showSnackBar("$errorMsg: ${res.error}",
                              color: Colors.red);
                        }
                      });
                    }
                  });
                },
                label: (user.pfpUrl.isEmpty)
                    ? dialogContext.l10n.add
                    : dialogContext.l10n.edit,
                color: GlobalThemeData.darkColorScheme.primary),

            // Delete pfp
            if (user.pfpUrl.isNotEmpty)
              SoftButton(
                onPressed: () {
                  // Delete profile picture from DB
                  final response = deleteProfilePicture();

                  // Cache localization
                  final successMsg = pageContext.l10n.pfp_deleted_success;
                  final errorMsg = pageContext.l10n.error_deleting_pfp;
                  Navigator.of(dialogContext).pop();

                  // Handle response
                  response.then((res) {
                    if (!mounted) return;

                    if (res.success) {
                      setState(() => user = user.copyWith(pfpUrl: null));
                      showSnackBar(successMsg, color: Colors.green);
                    } else {
                      showSnackBar("$errorMsg: ${res.error}",
                          color: Colors.red);
                    }
                  });
                },
                label: dialogContext.l10n.delete,
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
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
                              GestureDetector(
                                onTap: _handlePfpTap,
                                child: UserAvatar(user, radius: 60),
                              ),
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
                              prefixIcon:
                                  const Icon(Symbols.email_rounded, fill: 1),
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
                          subtitle:
                              Text(context.l10n.auto_save_imgs_description),
                          value: autoImageSave,
                          onChanged: (value) {
                            UserPreferences.setAutoImageSave(value);
                            setState(() => autoImageSave = value);
                          },
                        ),
                        SwitchListTile(
                          title: Text(context.l10n.group_comment_notifications),
                          subtitle: Text(context
                              .l10n.group_comment_notifications_description),
                          value: receiveAllGroupComments,
                          onChanged: (value) {
                            const errorPrefix = "Error updating setting";
                            final response =
                                setGroupCommentNotificationSetting(value);
                            response.then((res) {
                              if (res.success) {
                                if (!mounted) return;
                                setState(() => receiveAllGroupComments = value);
                              } else {
                                showSnackBar("$errorPrefix: ${res.error}",
                                    color: Colors.red);
                              }
                            });
                          },
                        ),
                        if (_developerOptionsUnlocked) ...[
                          const SizedBox(height: 35),
                          const Padding(
                            padding: EdgeInsets.only(left: 8.0),
                            child: Text(
                              'Developer',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SwitchListTile(
                            title: const Text('Debug Notifications'),
                            subtitle: const Text(
                                'Show notifications for widget updates and auth events'),
                            value: debugNotificationsEnabled,
                            onChanged: (value) async {
                              await UserPreferences.setDebugNotifications(value);
                              await DebugNotifier.instance.setEnabled(value);
                              setState(() => debugNotificationsEnabled = value);
                            },
                          ),
                        ],
                        const SizedBox(height: 40),
                        RectangleButton(
                          label: _isCheckingForUpdates
                              ? context.l10n.checking_for_updates
                              : context.l10n.check_for_updates,
                          icon: Symbols.system_update_rounded,
                          width: 200,
                          onPressed: _checkForUpdates,
                        ),
                        const SizedBox(height: 15),
                        RectangleButton(
                          label: context.l10n.log_out,
                          icon: Symbols.logout_rounded,
                          onPressed: _logout,
                          backgroundColor: Colors.redAccent,
                        ),
                      ],
                    ),
                  ),
                ),

                // Bottom text stays at the bottom
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
