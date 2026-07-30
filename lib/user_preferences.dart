import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/services/file_saver.dart';

/// Device-wide settings that belong to the person, not to any one backend.
///
/// Anything specific to a server — its URL, its anon key, its published config
/// — lives on that instance in `InstanceRegistry`, not here.
class UserPreferences {
  static SharedPreferences? _preferences;

  static late bool autoImageSave;
  static late bool isFirstLaunch;
  static late List<String> favoriteGroups;
  static late bool debugNotifications;
  static late bool developerOptionsUnlocked;
  static late int widgetRefreshIntervalMinutes;
  static late bool updateNotifications;

  Future<void> initPrefs() async {
    _preferences = await SharedPreferences.getInstance();

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

  /// How a group is named in the favourite and muted lists.
  ///
  /// Scoped to its instance: a group id only means something on the server that
  /// issued it, so two instances must not be able to mute each other's groups.
  static String groupKey(String instanceId, String groupId) =>
      '$instanceId/$groupId';

  /// Every favorite, as stored: `instanceId/groupId`.
  static Future<List<String>> getFavoriteGroups() async {
    return _preferences?.getStringList('favoriteGroups') ?? [];
  }

  /// The favorites on one instance.
  static Future<List<String>> favoriteGroupsOn(String instanceId) async {
    final prefix = '$instanceId/';
    return (_preferences?.getStringList('favoriteGroups') ?? [])
        .where((key) => key.startsWith(prefix))
        .map((key) => key.substring(prefix.length))
        .toList();
  }

  static Future<void> _setFavoriteGroups(List<String> groups) async {
    await _preferences?.setStringList('favoriteGroups', groups);
    favoriteGroups = groups;
  }

  static Future<void> addFavoriteGroup(String instanceId, String group) async {
    final key = groupKey(instanceId, group);
    final groups = _preferences?.getStringList('favoriteGroups') ?? [];
    if (groups.contains(key)) return;
    groups.add(key);
    await _setFavoriteGroups(groups);
  }

  static Future<void> removeFavoriteGroup(
      String instanceId, String group) async {
    final groups = _preferences?.getStringList('favoriteGroups') ?? [];
    groups.remove(groupKey(instanceId, group));
    await _setFavoriteGroups(groups);
  }

  static Future<bool> isGroupFavorite(String instanceId, String group) async {
    final favoriteGroups = _preferences?.getStringList('favoriteGroups') ?? [];
    return favoriteGroups.contains(groupKey(instanceId, group));
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

  static Future<bool> isGroupMuted(String instanceId, String group) async =>
      (await getMutedGroups()).contains(groupKey(instanceId, group));

  static Future<void> setGroupMuted(
      String instanceId, String group, bool muted) async {
    final prefs = await _prefs();
    final key = groupKey(instanceId, group);
    final groups = prefs.getStringList('mutedGroups') ?? [];
    if (muted) {
      if (!groups.contains(key)) groups.add(key);
    } else {
      groups.remove(key);
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
