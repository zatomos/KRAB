import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/image_crop_helper.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/dialogs/change_password_dialog.dart';
import 'package:krab/widgets/dialogs/edit_avatar_dialog.dart';
import 'package:krab/widgets/dialogs/rename_dialog.dart';
import 'package:krab/widgets/dialogs/update_dialog.dart';
import 'login_page.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  AccountPageState createState() => AccountPageState();
}

class AccountPageState extends State<AccountPage> {
  final _emailController = TextEditingController();
  final _updateService = UpdateService();

  krab_user.User user = const krab_user.User(id: '', username: '');

  bool _isLoading = false;

  bool autoImageSave = false;
  bool receiveAllGroupComments = false;
  bool debugNotificationsEnabled = false;
  bool updateNotificationsEnabled = true;
  bool _isCheckingForUpdates = false;
  bool _developerOptionsUnlocked = false;
  int _widgetRefreshInterval = 30;
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
      showSnackBar(context.l10n.no_user_logged_in, color: Colors.red);
      return;
    }

    final userResponse = await getUserDetails(authUser.id);
    final emailResponse = await getEmail();

    // Check auto image save preference
    autoImageSave = await UserPreferences.getAutoImageSave();

    // Check debug notifications preference
    debugNotificationsEnabled = await UserPreferences.getDebugNotifications();
    updateNotificationsEnabled = UserPreferences.updateNotifications;
    _developerOptionsUnlocked =
        await UserPreferences.getDeveloperOptionsUnlocked();
    final interval = await UserPreferences.getWidgetRefreshInterval();
    if (!mounted) return;
    setState(() => _widgetRefreshInterval = interval);

    if (!userResponse.success) {
      showSnackBar(
          context.l10n.error_loading_user(context.errorOr(userResponse.error)),
          color: Colors.red);
    }
    if (!emailResponse.success) {
      showSnackBar(
          context.l10n.error_loading_email(context.errorOr(emailResponse.error)),
          color: Colors.red);
    }

    // Load group comment notification setting
    final groupCommentSettingResponse =
        await getGroupCommentNotificationSetting();
    if (!mounted) return;

    if (!groupCommentSettingResponse.success) {
      showSnackBar(
        context.l10n.error_loading_notification_setting(
            context.errorOr(groupCommentSettingResponse.error)),
        color: Colors.red,
      );
    }

    setState(() {
      // Update user only if data is not null
      if (userResponse.data != null) {
        user = userResponse.data!;
      }

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
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        title: context.l10n.edit_username,
        hintText: context.l10n.username,
        initialValue: user.username,
        onSubmit: (value) async {
          final l10n = context.l10n;
          final res = await editUsername(value);
          return res.success
              ? null
              : "${l10n.error_updating_username}: ${res.error ?? l10n.unknown_error}";
        },
      ),
    );
    if (newName == null || !mounted) return;
    setState(() => user = user.copyWith(username: newName));
    showSnackBar(context.l10n.username_updated_success, color: Colors.green);
  }

  Future<void> openEditPfpDialog() async {
    final action = await showEditAvatarDialog(
      context,
      title: context.l10n.edit_pfp_title,
      hasImage: user.pfpUrl.isNotEmpty,
    );
    if (action == null || !mounted) return;

    if (action == AvatarAction.edit) {
      final file = await pickAndCropSquareImage();
      if (file == null || !mounted) return;

      final res = await editProfilePicture(file);
      if (!mounted) return;
      if (!res.success) {
        showSnackBar(
            "${context.l10n.error_updating_pfp}: ${context.errorOr(res.error)}",
            color: Colors.red);
        return;
      }

      // Fetch a fresh signed URL for the new picture.
      final newUrlResponse = await getProfilePictureUrl(user.id);
      if (!mounted) return;
      setState(() => user = user.copyWith(
          pfpUrl: newUrlResponse.success ? newUrlResponse.data : null));
      showSnackBar(context.l10n.pfp_updated_success, color: Colors.green);
    } else {
      final res = await deleteProfilePicture();
      if (!mounted) return;
      if (!res.success) {
        showSnackBar(
            "${context.l10n.error_deleting_pfp}: ${context.errorOr(res.error)}",
            color: Colors.red);
        return;
      }
      setState(() => user = user.copyWith(pfpUrl: null));
      showSnackBar(context.l10n.pfp_deleted_success, color: Colors.green);
    }
  }

  Future<void> openChangePasswordDialog() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => const ChangePasswordDialog(),
    );
    if (changed == true && mounted) {
      showSnackBar(context.l10n.password_updated_success, color: Colors.green);
    }
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
                        const SizedBox(height: 8),
                        ListTile(
                          leading: const Icon(Icons.lock_rounded),
                          title: Text(context.l10n.change_password),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: openChangePasswordDialog,
                        ),
                        const SizedBox(height: 27),
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
                            final l10n = context.l10n;
                            final response =
                                setGroupCommentNotificationSetting(value);
                            response.then((res) {
                              if (res.success) {
                                if (!mounted) return;
                                setState(() => receiveAllGroupComments = value);
                              } else {
                                showSnackBar(
                                    l10n.error_updating_setting(
                                        res.error ?? l10n.unknown_error),
                                    color: Colors.red);
                              }
                            });
                          },
                        ),
                        ListTile(
                          title: Text(context.l10n.widget_refresh_interval),
                          subtitle: Text(
                              context.l10n.widget_refresh_interval_description),
                          trailing: DropdownButton<int>(
                            value: _widgetRefreshInterval,
                            underline: const SizedBox.shrink(),
                            items: [
                              DropdownMenuItem(
                                  value: 0, child: Text(context.l10n.off)),
                              DropdownMenuItem(
                                  value: 15,
                                  child: Text(context.l10n.x_min(15))),
                              DropdownMenuItem(
                                  value: 30,
                                  child: Text(context.l10n.x_min(30))),
                              DropdownMenuItem(
                                  value: 60,
                                  child: Text(context.l10n.x_hour(1))),
                              DropdownMenuItem(
                                  value: 120,
                                  child: Text(context.l10n.x_hours(2))),
                              DropdownMenuItem(
                                  value: 360,
                                  child: Text(context.l10n.x_hours(6))),
                            ],
                            onChanged: (value) async {
                              if (value == null) return;
                              await UserPreferences.setWidgetRefreshInterval(
                                  value);
                              await scheduleWidgetRefresh(value, force: true);
                              setState(() => _widgetRefreshInterval = value);
                            },
                          ),
                        ),
                        if (UpdateService().isEnabled)
                          SwitchListTile(
                            title: Text(context.l10n.app_update_notifications),
                            subtitle: Text(context
                                .l10n.app_update_notifications_description),
                            value: updateNotificationsEnabled,
                            onChanged: (value) async {
                              await UserPreferences.setUpdateNotifications(
                                  value);
                              setState(
                                  () => updateNotificationsEnabled = value);
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
                              await UserPreferences.setDebugNotifications(
                                  value);
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
                          backgroundColor: Colors.red,
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
    _emailController.dispose();
    super.dispose();
  }
}
