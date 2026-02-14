import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:krab/services/file_saver.dart';

class UserPreferences {
  static SharedPreferences? _preferences;

  static late String supabaseUrl;
  static late String supabaseAnonKey;
  static late bool autoImageSave;
  static late bool isFirstLaunch;
  static late List<String> favoriteGroups;
  static late int widgetBitmapLimit;
  static late bool debugNotifications;
  static late bool developerOptionsUnlocked;

  Future<void> initPrefs() async {
    _preferences = await SharedPreferences.getInstance();

    supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
    supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';
    autoImageSave = _preferences?.getBool('autoImageSave') ?? false;
    isFirstLaunch = _preferences?.getBool('isFirstLaunch') ?? true;
    favoriteGroups = _preferences?.getStringList('favoriteGroups') ?? [];
    widgetBitmapLimit = 10 * 1024 * 1024; // Default 10 MB
    debugNotifications = _preferences?.getBool('debugNotifications') ?? false;
    developerOptionsUnlocked =
        _preferences?.getBool('developerOptionsUnlocked') ?? false;
  }

  static Future<int> getWidgetBitmapLimit() async {
    return _preferences?.getInt('widgetBitmapLimit') ?? (10 * 1024 * 1024);
  }

  static Future<void> setWidgetBitmapLimit(int bytes) async {
    await _preferences?.setInt('widgetBitmapLimit', bytes);
  }

  static Future<bool> getAutoImageSave() async {
    return _preferences?.getBool('autoImageSave') ?? false;
  }

  static Future<void> setAutoImageSave(bool value) async {
    // Check permissions
    if (value) {
      final permission = await checkAndRequestPermissions(skipIfExists: true);
      if (!permission) {
        return;
      }
    }

    await _preferences?.setBool('autoImageSave', value);
  }

  static Future<List<String>> getFavoriteGroups() async {
    return _preferences?.getStringList('favoriteGroups') ?? [];
  }

  static Future<void> addFavoriteGroup(String group) async {
    final favoriteGroups = _preferences?.getStringList('favoriteGroups') ?? [];
    favoriteGroups.add(group);
    await _preferences?.setStringList('favoriteGroups', favoriteGroups);
  }

  static Future<void> removeFavoriteGroup(String group) async {
    final favoriteGroups = _preferences?.getStringList('favoriteGroups') ?? [];
    favoriteGroups.remove(group);
    await _preferences?.setStringList('favoriteGroups', favoriteGroups);
  }

  static Future<bool> isGroupFavorite(String group) async {
    final favoriteGroups = _preferences?.getStringList('favoriteGroups') ?? [];
    return favoriteGroups.contains(group);
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

    // Reset all developer options to default when locked
    if (!value) {
      await setDebugNotifications(false);
    }
  }
}
