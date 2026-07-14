import 'package:flutter/material.dart';

import 'package:krab/services/auth/app_auth.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:krab/config.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/api/supabase.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/push_helper.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/dialogs/change_password_dialog.dart';
import 'package:krab/widgets/dialogs/change_server_dialog.dart';
import 'package:krab/widgets/dialogs/delete_account_dialog.dart';
import 'package:krab/widgets/dialogs/edit_avatar_dialog.dart';
import 'package:krab/widgets/dialogs/push_distributor_dialog.dart';
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
  bool receiveAllGroupReactions = false;
  bool debugNotificationsEnabled = false;
  bool updateNotificationsEnabled = true;
  bool _isCheckingForUpdates = false;
  bool _developerOptionsUnlocked = false;
  int _widgetRefreshInterval = 30;
  int _pfpTapCount = 0;

  String appVersion = "";

  /// The UnifiedPush distributor in use, null while loading or if none is set.
  String? _distributor;

  /// Whether the user has a delivery choice worth showing. See [_loadDistributor].
  bool _showDistributor = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _loadAppVersion();
    _loadDistributor();
  }

  Future<void> _loadDistributor() async {
    final distributors = await PushHelper.availableDistributors();
    final current = await PushHelper.currentDistributor();
    final packageName = (await PackageInfo.fromPlatform()).packageName;
    final onlyEmbedded =
        distributors.length == 1 && distributors.first == packageName;

    if (!mounted) return;
    setState(() {
      _distributor = current;
      _showDistributor = !onlyEmbedded;
    });
  }

  Future<void> _loadUserProfile() async {
    setState(() => _isLoading = true);

    final userId = AppAuth.instance.currentUserId;
    if (userId == null) {
      setState(() => _isLoading = false);
      showSnackBar(context.l10n.no_user_logged_in, tone: SnackTone.failure);
      return;
    }

    // Get user info
    final (userResponse, commentSetting, reactionSetting) = await (
      getUserDetails(userId),
      getGroupCommentNotificationSetting(),
      getGroupReactionNotificationSetting(),
    ).wait;
    final emailResponse = await getEmail();

    autoImageSave = await UserPreferences.getAutoImageSave();
    debugNotificationsEnabled = await UserPreferences.getDebugNotifications();
    updateNotificationsEnabled = UserPreferences.updateNotifications;
    _developerOptionsUnlocked =
        await UserPreferences.getDeveloperOptionsUnlocked();
    final interval = await UserPreferences.getWidgetRefreshInterval();
    if (!mounted) return;

    if (!userResponse.success) {
      showSnackBar(
          context.l10n
              .error_loading_user(context.errorText(userResponse.error)),
          tone: SnackTone.failure);
    }
    if (!emailResponse.success) {
      showSnackBar(
          context.l10n
              .error_loading_email(context.errorText(emailResponse.error)),
          tone: SnackTone.failure);
    }
    for (final setting in [commentSetting, reactionSetting]) {
      if (!setting.success) {
        showSnackBar(
          context.l10n.error_loading_notification_setting(
              context.errorText(setting.error)),
          tone: SnackTone.failure,
        );
      }
    }

    setState(() {
      _widgetRefreshInterval = interval;
      if (userResponse.data != null) user = userResponse.data!;
      _emailController.text = emailResponse.data ?? "";
      receiveAllGroupComments = commentSetting.data ?? receiveAllGroupComments;
      receiveAllGroupReactions =
          reactionSetting.data ?? receiveAllGroupReactions;
      _isLoading = false;
    });
  }

  /// Open the project's page in a browser.
  Future<void> _openProjectPage() async {
    final l10n = context.l10n;
    final opened = await launchUrl(
      Uri.parse(projectUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      showSnackBar(l10n.error_opening_link, tone: SnackTone.failure);
    }
  }

  Future<void> _loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      appVersion = packageInfo.version;
    });
  }

  Future<void> _logout() async {
    final res = await logOut();
    if (!mounted) return;

    // A logout that failed left the session on disk.
    if (!res.success) {
      showSnackBar(
        context.l10n.error_signing_out(context.errorText(res.error)),
        tone: SnackTone.failure,
      );
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  Future<void> openPushDistributorDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const PushDistributorDialog(),
    );
    // The dialog may have switched distributor, so re-read what is in use.
    await _loadDistributor();
  }

  Future<void> openChangeServerDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const ChangeServerDialog(),
    );
    // The dialog closes the app on a successful switch; if we are still here the
    // user cancelled, so just refresh the shown host.
    if (mounted) setState(() {});
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteAccountDialog(username: user.username),
    );
    if (confirmed != true || !mounted) return;

    final res = await deleteAccount();
    if (!mounted) return;

    if (!res.success) {
      // The server refuses while the user still owns a group
      final message = res.error == 'owns_groups'
          ? context.l10n.delete_account_owns_groups
          : context.l10n.error_deleting_account(context.errorText(res.error));
      showSnackBar(message, tone: SnackTone.failure);
      return;
    }

    showSnackBar(context.l10n.account_deleted_success, tone: SnackTone.success);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  Future<void> _checkForUpdates() async {
    if (_isCheckingForUpdates) return;

    setState(() => _isCheckingForUpdates = true);
    final result = await _updateService.checkForUpdate();
    if (!mounted) return;
    setState(() => _isCheckingForUpdates = false);

    if (!result.success) {
      showSnackBar(
        context.l10n.update_check_failed,
        tone: SnackTone.warning,
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

    showSnackBar(context.l10n.no_update_available, tone: SnackTone.success);
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
      showSnackBar('Developer options unlocked', tone: SnackTone.success);
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
        maxLength: 19,
        onSubmit: (value) async {
          final l10n = context.l10n;
          final res = await editUsername(value);
          return res.success
              ? null
              : "${l10n.error_updating_username}: ${describeError(l10n, res.error)}";
        },
      ),
    );
    if (newName == null || !mounted) return;
    setState(() => user = user.copyWith(username: newName));
    showSnackBar(context.l10n.username_updated_success,
        tone: SnackTone.success);
  }

  Future<void> openEditPfpDialog() async {
    final l10n = context.l10n;
    final change = await editAvatar(
      context,
      AvatarTarget(
        hasImage: user.pfpUrl.isNotEmpty,
        dialogTitle: l10n.edit_pfp_title,
        upload: editProfilePicture,
        remove: deleteProfilePicture,
        freshUrl: () => getProfilePictureUrl(user.id),
        uploadFailed: l10n.error_updating_pfp,
        removeFailed: l10n.error_deleting_pfp,
        uploadSucceeded: l10n.pfp_updated_success,
        removeSucceeded: l10n.pfp_deleted_success,
      ),
    );
    if (change == null || !mounted) return;
    setState(() => user = user.copyWith(pfpUrl: change.url));
  }

  Future<void> openChangePasswordDialog() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => const ChangePasswordDialog(),
    );
    if (changed == true && mounted) {
      showSnackBar(context.l10n.password_updated_success,
          tone: SnackTone.success);
    }
  }

  /// The backend's hostname, falling back to the raw URL if it can't be parsed.
  String get _serverHost {
    final host = Uri.tryParse(UserPreferences.supabaseUrl)?.host ?? '';
    return host.isNotEmpty ? host : UserPreferences.supabaseUrl;
  }

  /// A switch whose state lives on the server.
  Widget _serverSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required Future<SupabaseResponse<void>> Function(bool) save,
    required void Function(bool) apply,
  }) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (next) async {
        final l10n = context.l10n;
        final res = await save(next);
        if (!mounted) return;
        if (res.success) {
          setState(() => apply(next));
        } else {
          showSnackBar(
              l10n.error_updating_setting(res.error ?? l10n.unknown_error),
              tone: SnackTone.failure);
        }
      },
    );
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
                        ListTile(
                          leading: const Icon(Icons.dns_rounded),
                          title: Text(context.l10n.server_label),
                          subtitle: Text(_serverHost),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: openChangeServerDialog,
                        ),
                        if (_showDistributor)
                          ListTile(
                            leading:
                                const Icon(Icons.notifications_active_rounded),
                            title: Text(context.l10n.push_distributor_label),
                            subtitle: Text(
                              _distributor ??
                                  context.l10n.push_distributor_none_selected,
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: openPushDistributorDialog,
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
                        _serverSwitch(
                          title: context.l10n.group_comment_notifications,
                          subtitle: context
                              .l10n.group_comment_notifications_description,
                          value: receiveAllGroupComments,
                          save: setGroupCommentNotificationSetting,
                          apply: (v) => receiveAllGroupComments = v,
                        ),
                        _serverSwitch(
                          title: context.l10n.group_reaction_notifications,
                          subtitle: context
                              .l10n.group_reaction_notifications_description,
                          value: receiveAllGroupReactions,
                          save: setGroupReactionNotificationSetting,
                          apply: (v) => receiveAllGroupReactions = v,
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
                        if (_updateService.isEnabled)
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
                        // Hidden when this build has no repo to update from, or
                        // updates are off
                        if (_updateService.isEnabled) ...[
                          RectangleButton(
                            label: _isCheckingForUpdates
                                ? context.l10n.checking_for_updates
                                : context.l10n.check_for_updates,
                            icon: Symbols.system_update_rounded,
                            width: 200,
                            onPressed: _checkForUpdates,
                          ),
                          const SizedBox(height: 15),
                        ],
                        RectangleButton(
                          label: context.l10n.log_out,
                          icon: Symbols.logout_rounded,
                          onPressed: _logout,
                          backgroundColor: Colors.red,
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _deleteAccount,
                          icon: const Icon(Symbols.delete_forever_rounded,
                              size: 20),
                          label: Text(context.l10n.delete_account),
                          style: TextButton.styleFrom(
                            foregroundColor:
                                Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Bottom text stays at the bottom
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'KRAB v$appVersion',
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(SimpleIcons.github, size: 18),
                        color: Colors.grey,
                        visualDensity: VisualDensity.compact,
                        onPressed: _openProjectPage,
                      ),
                    ],
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
