import 'package:flutter/material.dart';
import 'package:krab/themes/global_theme_data.dart';

import 'package:material_symbols_icons/symbols.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:krab/config.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/user_preferences.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/settings_section.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/dialogs/change_password_dialog.dart';
import 'package:krab/widgets/dialogs/delete_account_dialog.dart';
import 'package:krab/widgets/dialogs/edit_avatar_dialog.dart';
import 'package:krab/widgets/dialogs/rename_dialog.dart';
import 'package:krab/widgets/dialogs/update_dialog.dart';
import 'package:krab/pages/camera_page.dart';
import 'package:krab/pages/servers_page.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/instance/instances.dart';

/// Which group activity the user wants notifications for.
enum GroupNotificationSetting { none, comments, reactions, both }

class AccountPage extends StatefulWidget {
  /// The server whose account this is.
  final KrabInstance instance;

  /// Whether the servers page sits directly beneath this one.
  final bool fromServers;

  const AccountPage({
    super.key,
    required this.instance,
    this.fromServers = false,
  });

  @override
  AccountPageState createState() => AccountPageState();
}

class AccountPageState extends State<AccountPage> {
  KrabApi get _api => widget.instance.api;

  String _email = '';
  final _updateService = UpdateService();

  krab_user.User user =
      const krab_user.User(instanceId: '', id: '', username: '');

  bool _isLoading = false;

  bool autoImageSave = false;
  bool receiveAllGroupComments = false;
  bool receiveAllGroupReactions = false;
  bool debugNotificationsEnabled = false;
  bool updateNotificationsEnabled = true;
  bool _isCheckingForUpdates = false;
  bool _developerOptionsUnlocked = false;
  int _widgetRefreshInterval = 30;
  int _versionTapCount = 0;

  String appVersion = "";

  /// Whether the app is exempt from battery optimization. Null while loading.
  bool? _batteryOptimizationDisabled;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _loadAppVersion();
    _loadBatteryOptimization();
  }

  Future<void> _loadBatteryOptimization() async {
    final granted = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!mounted) return;
    setState(() => _batteryOptimizationDisabled = granted);
  }

  /// Prompts for the battery-optimization exemption, sending the user to system
  /// settings if the request can no longer be shown as a dialog.
  Future<void> _requestBatteryOptimization() async {
    if (_batteryOptimizationDisabled == true) {
      // Already exempt; the toggle can only be reversed from system settings.
      await openAppSettings();
    } else if (await Permission
        .ignoreBatteryOptimizations.isPermanentlyDenied) {
      await openAppSettings();
    } else {
      await Permission.ignoreBatteryOptimizations.request();
    }
    await _loadBatteryOptimization();
  }

  Future<void> _loadUserProfile() async {
    setState(() => _isLoading = true);

    final userId = widget.instance.auth.currentUserId;
    if (userId == null) {
      setState(() => _isLoading = false);
      showSnackBar(context.l10n.no_user_logged_in, tone: SnackTone.failure);
      return;
    }

    // Get user info
    final (userResponse, commentSetting, reactionSetting) = await (
      _api.getUserDetails(userId),
      _api.getGroupCommentNotificationSetting(),
      _api.getGroupReactionNotificationSetting(),
    ).wait;
    final emailResponse = await _api.getEmail();

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
      _email = emailResponse.data ?? "";
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
    final res = await _api.logOut();
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
      MaterialPageRoute(builder: (context) => signInScreen()),
    );
  }

  /// How many servers this install is connected to.
  int get _serverCount => InstanceRegistry.instance.all.length;

  String get _serverAddress {
    final url = widget.instance.url;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return url;
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path == '/' ? '' : uri.path;
    return '${uri.host}$port$path';
  }

  Future<void> openServersPage() async {
    // Came from there: step back rather than opening a second one.
    if (widget.fromServers) {
      Navigator.of(context).pop();
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ServersPage()),
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteAccountDialog(username: user.username),
    );
    if (confirmed != true || !mounted) return;

    final res = await _api.deleteAccount();
    if (!mounted) return;

    if (!res.success) {
      // The server refuses while the user still owns a group
      final message = res.error == 'owns_groups'
          ? context.l10n.delete_account_owns_groups
          : context.l10n.error_deleting_account(context.errorText(res.error));
      showSnackBar(message, tone: SnackTone.failure);
      return;
    }

    final message = context.l10n.account_deleted_success;

    // Forget server
    await InstanceRegistry.instance.remove(widget.instance.id);
    if (!mounted) return;

    showSnackBar(message, tone: SnackTone.success);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (context) => anySignedIn ? const CameraPage() : signInScreen(),
      ),
      (route) => false,
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

  /// Taps on the version line unlock the developer section.
  Future<void> _handleVersionTap() async {
    _versionTapCount++;
    debugPrint("Version tapped $_versionTapCount times");
    if (_versionTapCount < 10) return;

    final nextValue = !_developerOptionsUnlocked;
    await UserPreferences.setDeveloperOptionsUnlocked(nextValue);
    if (!mounted) return;

    setState(() {
      _developerOptionsUnlocked = nextValue;
      _versionTapCount = 0;
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
          final res = await _api.editUsername(value);
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
        upload: _api.editProfilePicture,
        remove: _api.deleteProfilePicture,
        freshUrl: () => _api.getProfilePictureUrl(user.id),
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
      builder: (_) => ChangePasswordDialog(instance: widget.instance),
    );
    if (changed == true && mounted) {
      showSnackBar(context.l10n.password_updated_success,
          tone: SnackTone.success);
    }
  }

  /// The merged group-notification choice.
  GroupNotificationSetting get _groupNotificationSetting {
    if (receiveAllGroupComments && receiveAllGroupReactions) {
      return GroupNotificationSetting.both;
    }
    if (receiveAllGroupComments) return GroupNotificationSetting.comments;
    if (receiveAllGroupReactions) return GroupNotificationSetting.reactions;
    return GroupNotificationSetting.none;
  }

  /// Apply a merged group-notification choice by saving whichever of the two
  /// server flags actually changed.
  Future<void> _setGroupNotificationSetting(
      GroupNotificationSetting setting) async {
    final l10n = context.l10n;
    final wantComments = setting == GroupNotificationSetting.comments ||
        setting == GroupNotificationSetting.both;
    final wantReactions = setting == GroupNotificationSetting.reactions ||
        setting == GroupNotificationSetting.both;

    const ok = SupabaseResponse<void>(success: true);
    final (commentRes, reactionRes) = await (
      wantComments != receiveAllGroupComments
          ? _api.setGroupCommentNotificationSetting(wantComments)
          : Future.value(ok),
      wantReactions != receiveAllGroupReactions
          ? _api.setGroupReactionNotificationSetting(wantReactions)
          : Future.value(ok),
    ).wait;
    if (!mounted) return;

    setState(() {
      if (commentRes.success) receiveAllGroupComments = wantComments;
      if (reactionRes.success) receiveAllGroupReactions = wantReactions;
    });

    final failed = !commentRes.success ? commentRes : reactionRes;
    if (!failed.success) {
      showSnackBar(
          l10n.error_updating_setting(failed.error ?? l10n.unknown_error),
          tone: SnackTone.failure);
    }
  }

  String _groupNotificationLabel(
          BuildContext context, GroupNotificationSetting setting) =>
      switch (setting) {
        GroupNotificationSetting.none => context.l10n.group_activity_none,
        GroupNotificationSetting.comments =>
          context.l10n.group_activity_comments,
        GroupNotificationSetting.reactions =>
          context.l10n.group_activity_reactions,
        GroupNotificationSetting.both => context.l10n.group_activity_both,
      };

  void _backToCamera() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToCamera();
      },
      child: _buildScaffold(context),
    );
  }

  Scaffold _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.account_page_title)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(context),
                        const SectionDivider(),
                        _accountSection(context),
                        const SectionDivider(),
                        _settingsSection(context),
                        if (_developerOptionsUnlocked) ...[
                          const SectionDivider(),
                          _developerSection(context),
                        ],
                        const SizedBox(height: settingsGapL),
                        _actions(context),
                      ],
                    ),
                  ),
                ),
                _versionFooter(context),
              ],
            ),
    );
  }

  /// User profile
  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const nameStyle = TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w500,
        letterSpacing: GlobalThemeData.mediumTracking);

    return Column(
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            GestureDetector(
              onTap: openEditPfpDialog,
              child: UserAvatar(user, radius: 60),
            ),
            GestureDetector(
              onTap: openEditPfpDialog,
              child: CircleAvatar(
                radius: 16,
                backgroundColor: colors.surfaceBright,
                child: Icon(Symbols.photo_camera_rounded,
                    size: 18, color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: settingsGapM),
        GestureDetector(
          onTap: openEditUsernameDialog,
          child: Stack(
            children: [
              Center(
                child: Text(user.username,
                    textAlign: TextAlign.center, style: nameStyle),
              ),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: 0,
                      child: Text(user.username, style: nameStyle),
                    ),
                    Transform.translate(
                      offset: const Offset(20, -2),
                      child: Icon(
                        Icons.keyboard_arrow_right_rounded,
                        size: 40,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _accountSection(BuildContext context) {
    return SettingsSection(
      title: context.l10n.profile_section,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Symbols.email_rounded, fill: 1),
            title: Text(context.l10n.email),
            subtitle: Text(
              _email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_rounded),
            title: Text(context.l10n.change_password),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: openChangePasswordDialog,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_rounded),
            title: Text(_serverCount > 1
                ? context.l10n.server_label_count(_serverCount)
                : context.l10n.server_label),
            subtitle: Text(
              _serverAddress,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: openServersPage,
          ),
        ],
      ),
    );
  }

  Widget _settingsSection(BuildContext context) {
    return SettingsSection(
      title: context.l10n.settings,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.group_activity_notifications),
            subtitle: Text(context.l10n.group_activity_notifications_description),
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: DropdownButton<GroupNotificationSetting>(
                value: _groupNotificationSetting,
                isExpanded: true,
                itemHeight: null,
                underline: const SizedBox.shrink(),
                // Let the selected label wrap onto multiple lines.
                selectedItemBuilder: (context) => [
                  for (final setting in GroupNotificationSetting.values)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        _groupNotificationLabel(context, setting),
                        textAlign: TextAlign.end,
                      ),
                    ),
                ],
                items: [
                  for (final setting in GroupNotificationSetting.values)
                    DropdownMenuItem(
                      value: setting,
                      child: Text(_groupNotificationLabel(context, setting)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) _setGroupNotificationSetting(value);
                },
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.auto_save_imgs),
            subtitle: Text(context.l10n.auto_save_imgs_description),
            value: autoImageSave,
            onChanged: (value) {
              UserPreferences.setAutoImageSave(value);
              setState(() => autoImageSave = value);
            },
          ),
          if (_updateService.isEnabled)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.app_update_notifications),
              subtitle: Text(context.l10n.app_update_notifications_description),
              value: updateNotificationsEnabled,
              onChanged: (value) async {
                await UserPreferences.setUpdateNotifications(value);
                setState(() => updateNotificationsEnabled = value);
              },
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.widget_refresh_interval),
            subtitle: Text(context.l10n.widget_refresh_interval_description),
            trailing: DropdownButton<int>(
              value: _widgetRefreshInterval,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: 0, child: Text(context.l10n.off)),
                DropdownMenuItem(
                    value: 15, child: Text(context.l10n.x_min(15))),
                DropdownMenuItem(
                    value: 30, child: Text(context.l10n.x_min(30))),
                DropdownMenuItem(
                    value: 60, child: Text(context.l10n.x_hour(1))),
                DropdownMenuItem(
                    value: 120, child: Text(context.l10n.x_hours(2))),
                DropdownMenuItem(
                    value: 360, child: Text(context.l10n.x_hours(6))),
              ],
              onChanged: (value) async {
                if (value == null) return;
                await UserPreferences.setWidgetRefreshInterval(value);
                await scheduleWidgetRefresh(value, force: true);
                setState(() => _widgetRefreshInterval = value);
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
                _batteryOptimizationDisabled == true
                    ? Icons.battery_charging_full_rounded
                    : Icons.battery_alert_rounded,
                color: _batteryOptimizationDisabled == false
                    ? Theme.of(context).colorScheme.error
                    : GlobalThemeData.success),
            title: Text(context.l10n.battery_optimization_label),
            subtitle: Text(
              _batteryOptimizationDisabled == true
                  ? context.l10n.battery_optimization_allowed
                  : context.l10n.battery_optimization_restricted,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _requestBatteryOptimization,
          ),
        ],
      ),
    );
  }

  Widget _developerSection(BuildContext context) {
    return SettingsSection(
      title: 'Developer',
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Debug Notifications'),
        subtitle:
            const Text('Show notifications for widget updates and auth events'),
        value: debugNotificationsEnabled,
        onChanged: (value) async {
          await UserPreferences.setDebugNotifications(value);
          await DebugNotifier.instance.setEnabled(value);
          setState(() => debugNotificationsEnabled = value);
        },
      ),
    );
  }

  /// Sign out buttons.
  Widget _actions(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hidden when this build has no repo to update from, or updates are off
        if (_updateService.isEnabled) ...[
          RectangleButton(
            label: _isCheckingForUpdates
                ? context.l10n.checking_for_updates
                : context.l10n.check_for_updates,
            icon: Symbols.system_update_rounded,
            loading: _isCheckingForUpdates,
            style: RectangleButtonStyle.outlined,
            onPressed: _checkForUpdates,
          ),
          const SizedBox(height: settingsGapL),
        ],
        RectangleButton(
          label: context.l10n.log_out,
          icon: Symbols.logout_rounded,
          onPressed: _logout,
          style: RectangleButtonStyle.outlined,
          backgroundColor: error,
        ),
        const SizedBox(height: settingsGapS),
        RectangleButton(
          label: context.l10n.delete_account,
          icon: Symbols.delete_forever_rounded,
          onPressed: _deleteAccount,
          backgroundColor: error,
        ),
      ],
    );
  }

  /// KRAB app info
  Widget _versionFooter(BuildContext context) => Padding(
        padding: const EdgeInsets.all(settingsGapS),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: _handleVersionTap,
              child: Text(
                'KRAB v$appVersion',
                style: const TextStyle(color: Colors.grey),
              ),
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
      );
}
