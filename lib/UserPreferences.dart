import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/filesaver.dart';

class UserPreferences {
  static SharedPreferences? _preferences;

  static late String supabaseUrl;
  static late String supabaseAnonKey;
  static late bool autoImageSave;
  static late bool isFirstLaunch;
  static late List<String> favoriteGroups;
  static late int widgetBitmapLimit;

  Future<void> initPrefs() async {
    _preferences = await SharedPreferences.getInstance();

    supabaseUrl = _preferences?.getString('supabaseUrl') ??
        '';
    supabaseAnonKey = _preferences?.getString('supabaseAnonKey') ??
        '';
    autoImageSave = _preferences?.getBool('autoImageSave') ?? false;
    isFirstLaunch = _preferences?.getBool('isFirstLaunch') ?? true;
    favoriteGroups = _preferences?.getStringList('favoriteGroups') ?? [];
    widgetBitmapLimit = 10 * 1024 * 1024; // Default 10 MB
  }

  static Future<void> setSupabaseConfig(String url, String anonKey) async {
    await _preferences?.setString('supabaseUrl', url);
    await _preferences?.setString('supabaseAnonKey', anonKey);
  }

  static Future<String> getSupabaseConfig() async {
    final url = _preferences?.getString('supabaseUrl') ?? '';
    final anonKey = _preferences?.getString('supabaseAnonKey') ?? '';
    return 'URL: $url\nAnon Key: $anonKey';
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
}
