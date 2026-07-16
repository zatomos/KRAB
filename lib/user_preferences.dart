import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/config.dart';
import 'package:krab/services/file_saver.dart';

class UserPreferences {
  static SharedPreferences? _preferences;

  static late String supabaseUrl;
  static late String supabaseAnonKey;

  // Per-instance settings, fetched from the instance-config edge function and
  // cached here.
  static late String fcmAppId;
  static late String fcmApiKey;
  static late String fcmSenderId;
  static late String fcmProjectId;
  static late String passwordResetUrl;
  static late String emailConfirmUrl;
  static late bool autoImageSave;
  static late bool isFirstLaunch;
  static late List<String> favoriteGroups;
  static late bool debugNotifications;
  static late bool developerOptionsUnlocked;
  static late int widgetRefreshIntervalMinutes;
  static late bool updateNotifications;

  /// Trims a config value and strips a matching pair of surrounding quotes
  static String _clean(String? raw) {
    var v = (raw ?? '').trim();
    if (v.length >= 2 &&
        ((v.startsWith("'") && v.endsWith("'")) ||
            (v.startsWith('"') && v.endsWith('"')))) {
      v = v.substring(1, v.length - 1).trim();
    }
    return v;
  }

  Future<void> initPrefs() async {
    _preferences = await SharedPreferences.getInstance();

    supabaseUrl =
        _clean(_preferences?.getString('supabaseUrl') ?? bakedSupabaseUrl);
    supabaseAnonKey = _clean(
        _preferences?.getString('supabaseAnonKey') ?? bakedSupabaseAnonKey);

    // Seed a baked-in default into prefs on first launch, so that from then on
    // prefs are the single source of truth and the user can still switch away.
    // Only when we have a usable pair, so the generic build writes nothing and
    // comes up on the connect screen.
    if (supabaseUrl.isNotEmpty &&
        supabaseAnonKey.isNotEmpty &&
        _preferences?.getString('supabaseUrl') != supabaseUrl) {
      await _preferences?.setString('supabaseUrl', supabaseUrl);
      await _preferences?.setString('supabaseAnonKey', supabaseAnonKey);
    }
    fcmAppId = _preferences?.getString('fcmAppId') ?? '';
    fcmApiKey = _preferences?.getString('fcmApiKey') ?? '';
    fcmSenderId = _preferences?.getString('fcmSenderId') ?? '';
    fcmProjectId = _preferences?.getString('fcmProjectId') ?? '';
    passwordResetUrl = _preferences?.getString('passwordResetUrl') ?? '';
    emailConfirmUrl = _preferences?.getString('emailConfirmUrl') ?? '';
    autoImageSave = _preferences?.getBool('autoImageSave') ?? false;
    isFirstLaunch = _preferences?.getBool('isFirstLaunch') ?? true;
    favoriteGroups = _preferences?.getStringList('favoriteGroups') ?? [];
    debugNotifications = _preferences?.getBool('debugNotifications') ?? false;
    developerOptionsUnlocked =
        _preferences?.getBool('developerOptionsUnlocked') ?? false;
    widgetRefreshIntervalMinutes =
        _preferences?.getInt('widgetRefreshIntervalMinutes') ?? 30;
    updateNotifications = _preferences?.getBool('updateNotifications') ?? true;
  }

  /// Points this install at a KRAB backend.
  static Future<void> setSupabaseConfig({
    required String url,
    required String anonKey,
  }) async {
    supabaseUrl = url;
    supabaseAnonKey = anonKey;
    await _preferences?.setString('supabaseUrl', url);
    await _preferences?.setString('supabaseAnonKey', anonKey);
    await clearInstanceConfig();
  }

  /// True once this install knows which backend to talk to.
  static bool get hasSupabaseConfig =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Caches what the instance-config endpoint reported for this backend.
  static Future<void> setInstanceConfig({
    required String fcmAppId,
    required String fcmApiKey,
    required String fcmSenderId,
    required String fcmProjectId,
    required String resetUrl,
    required String confirmUrl,
  }) async {
    UserPreferences.fcmAppId = fcmAppId;
    UserPreferences.fcmApiKey = fcmApiKey;
    UserPreferences.fcmSenderId = fcmSenderId;
    UserPreferences.fcmProjectId = fcmProjectId;
    passwordResetUrl = resetUrl;
    emailConfirmUrl = confirmUrl;
    await _preferences?.setString('fcmAppId', fcmAppId);
    await _preferences?.setString('fcmApiKey', fcmApiKey);
    await _preferences?.setString('fcmSenderId', fcmSenderId);
    await _preferences?.setString('fcmProjectId', fcmProjectId);
    await _preferences?.setString('passwordResetUrl', resetUrl);
    await _preferences?.setString('emailConfirmUrl', confirmUrl);
  }

  /// True once this instance's FCM config is known, so Firebase can be brought
  /// up.
  static bool get hasFcmConfig =>
      fcmAppId.isNotEmpty &&
      fcmApiKey.isNotEmpty &&
      fcmSenderId.isNotEmpty &&
      fcmProjectId.isNotEmpty;

  static Future<void> clearInstanceConfig() async {
    fcmAppId = '';
    fcmApiKey = '';
    fcmSenderId = '';
    fcmProjectId = '';
    passwordResetUrl = '';
    emailConfirmUrl = '';
    await _preferences?.remove('fcmAppId');
    await _preferences?.remove('fcmApiKey');
    await _preferences?.remove('fcmSenderId');
    await _preferences?.remove('fcmProjectId');
    await _preferences?.remove('passwordResetUrl');
    await _preferences?.remove('emailConfirmUrl');
  }

  static Future<bool> getAutoImageSave() async {
    return _preferences?.getBool('autoImageSave') ?? false;
  }

  static Future<void> setAutoImageSave(bool value) async {
    if (value) {
      final permission = await checkAndRequestPermissions(skipIfExists: true);
      if (!permission) return;
    }
    await _preferences?.setBool('autoImageSave', value);
    autoImageSave = value;
  }

  static Future<List<String>> getFavoriteGroups() async {
    return _preferences?.getStringList('favoriteGroups') ?? [];
  }

  static Future<void> _setFavoriteGroups(List<String> groups) async {
    await _preferences?.setStringList('favoriteGroups', groups);
    favoriteGroups = groups;
  }

  static Future<void> addFavoriteGroup(String group) async {
    final groups = _preferences?.getStringList('favoriteGroups') ?? [];
    if (groups.contains(group)) return;
    groups.add(group);
    await _setFavoriteGroups(groups);
  }

  static Future<void> removeFavoriteGroup(String group) async {
    final groups = _preferences?.getStringList('favoriteGroups') ?? [];
    groups.remove(group);
    await _setFavoriteGroups(groups);
  }

  static Future<bool> isGroupFavorite(String group) async {
    final favoriteGroups = _preferences?.getStringList('favoriteGroups') ?? [];
    return favoriteGroups.contains(group);
  }

  // Groups whose notifications the user has muted. Read with a fresh
  // SharedPreferences handle so it also works in the push background isolate,
  // where the static _preferences is never initialized.
  static Future<SharedPreferences> _prefs() async =>
      _preferences ?? await SharedPreferences.getInstance();

  static Future<List<String>> getMutedGroups() async {
    final prefs = await _prefs();
    await prefs.reload();
    return prefs.getStringList('mutedGroups') ?? [];
  }

  static Future<bool> isGroupMuted(String group) async =>
      (await getMutedGroups()).contains(group);

  static Future<void> setGroupMuted(String group, bool muted) async {
    final prefs = await _prefs();
    final groups = prefs.getStringList('mutedGroups') ?? [];
    if (muted) {
      if (!groups.contains(group)) groups.add(group);
    } else {
      groups.remove(group);
    }
    await prefs.setStringList('mutedGroups', groups);
  }

  static Future<bool> getIsFirstLaunch() async {
    return _preferences?.getBool('isFirstLaunch') ?? true;
  }

  static Future<void> notFirstLaunch() async {
    await _preferences?.setBool('isFirstLaunch', false);
    isFirstLaunch = false;
  }

  static Future<bool> getDebugNotifications() async {
    return _preferences?.getBool('debugNotifications') ?? false;
  }

  static Future<void> setDebugNotifications(bool value) async {
    await _preferences?.setBool('debugNotifications', value);
    debugNotifications = value;
  }

  static Future<bool> getDeveloperOptionsUnlocked() async {
    return _preferences?.getBool('developerOptionsUnlocked') ?? false;
  }

  static Future<void> setDeveloperOptionsUnlocked(bool value) async {
    await _preferences?.setBool('developerOptionsUnlocked', value);
    developerOptionsUnlocked = value;

    if (!value) {
      await setDebugNotifications(false);
    }
  }

  static Future<int> getWidgetRefreshInterval() async {
    return _preferences?.getInt('widgetRefreshIntervalMinutes') ?? 30;
  }

  static Future<void> setWidgetRefreshInterval(int minutes) async {
    await _preferences?.setInt('widgetRefreshIntervalMinutes', minutes);
    widgetRefreshIntervalMinutes = minutes;
  }

  static Future<String?> getLastWidgetImageId() async {
    return _preferences?.getString('lastWidgetImageId');
  }

  static Future<void> setLastWidgetImageId(String id) async {
    await _preferences?.setString('lastWidgetImageId', id);
  }

  // ---- App-update notifications ----------------------------------------

  static Future<void> setUpdateNotifications(bool value) async {
    await _preferences?.setBool('updateNotifications', value);
    updateNotifications = value;
  }

  /// Epoch ms of the last background update check.
  static int getLastUpdateCheckMillis() {
    return _preferences?.getInt('lastUpdateCheckMillis') ?? 0;
  }

  static Future<void> setLastUpdateCheckMillis(int millis) async {
    await _preferences?.setInt('lastUpdateCheckMillis', millis);
  }
}
