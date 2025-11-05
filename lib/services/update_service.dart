import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:android_package_installer/android_package_installer.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final List<String> changelog;
  final bool forceUpdate;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.changelog,
    this.forceUpdate = false,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['latestVersion'] ?? '',
      downloadUrl: json['downloadUrl'] ?? '',
      changelog: List<String>.from(json['changelog'] ?? []),
      forceUpdate: json['forceUpdate'] ?? false,
    );
  }
}

class UpdateService {
  final Dio _dio = Dio();

  String get manifestUrl => dotenv.env['MANIFEST_URL'] ?? '';
  bool get isEnabled => (dotenv.env['ENABLE_AUTO_UPDATE']?.toLowerCase() == 'true');

  Future<UpdateInfo?> checkForUpdate() async {
    if (!isEnabled) return null;

    try {
      final response = await _dio.get(manifestUrl);

      dynamic rawData = response.data;
      if (rawData is String) {
        rawData = jsonDecode(rawData);
      }

      final updateInfo = UpdateInfo.fromJson(rawData);
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (_isUpdateAvailable(currentVersion, updateInfo.version)) {
        return updateInfo;
      }
      return null;
    } catch (e) {
      debugPrint('Error checking for updates: $e');
      return null;
    }
  }

  Future<bool> downloadAndInstall(
      String downloadUrl,
      Function(double) onProgress,
      ) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/app_update.apk';
      final file = File(savePath);
      if (await file.exists()) await file.delete();

      debugPrint('Downloading update to $savePath ...');

      await _dio.download(
        downloadUrl,
        savePath,
        onReceiveProgress: (received, total) {
          if (total != -1) onProgress(received / total);
        },
      );

      debugPrint('Download complete, launching installer...');
      final statusCode =
      await AndroidPackageInstaller.installApk(apkFilePath: savePath);

      if (statusCode != null) {
        final status = PackageInstallerStatus.byCode(statusCode);
        debugPrint('Installer status: $status');
        return status == PackageInstallerStatus.success;
      }
      return false;
    } catch (e) {
      debugPrint('Error during install: $e');
      return false;
    }
  }

  bool _isUpdateAvailable(String current, String latest) {
    try {
      final currentParts = current.split('.').map(int.parse).toList();
      final latestParts = latest.split('.').map(int.parse).toList();

      while (currentParts.length < 3) {
        currentParts.add(0);
      }
      while (latestParts.length < 3) {
        latestParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}