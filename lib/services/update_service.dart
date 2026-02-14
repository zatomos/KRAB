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

class UpdateCheckResult {
  final UpdateInfo? info;
  final bool success;
  final bool hasUpdate;

  UpdateCheckResult({
    required this.success,
    required this.hasUpdate,
    this.info,
  });
}

class UpdateService {
  final Dio _dio = Dio();

  String get manifestUrl => dotenv.env['MANIFEST_URL'] ?? '';
  bool get isEnabled =>
      (dotenv.env['ENABLE_AUTO_UPDATE']?.toLowerCase() == 'true');

  Future<UpdateCheckResult> checkForUpdate({bool requireEnabled = true}) async {
    if (requireEnabled && !isEnabled) {
      return UpdateCheckResult(success: false, hasUpdate: false);
    }

    try {
      final response = await _dio.get(manifestUrl);
      dynamic rawData = response.data;
      if (rawData is String) rawData = jsonDecode(rawData);

      final updateInfo = UpdateInfo.fromJson(rawData);
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final hasUpdate = _isUpdateAvailable(currentVersion, updateInfo.version);
      return UpdateCheckResult(
          success: true,
          hasUpdate: hasUpdate,
          info: hasUpdate ? updateInfo : null);
    } catch (e) {
      debugPrint('Error checking for updates: $e');
      return UpdateCheckResult(success: false, hasUpdate: false);
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
      final currentParsed = _parseVersion(current);
      final latestParsed = _parseVersion(latest);

      final currentNumbers = currentParsed[0] as List<int>;
      final latestNumbers = latestParsed[0] as List<int>;

      final currentStage = currentParsed[1] as int;
      final latestStage = latestParsed[1] as int;

      final currentStageNumber = currentParsed[2] as int;
      final latestStageNumber = latestParsed[2] as int;

      for (int i = 0; i < 3; i++) {
        if (latestNumbers[i] > currentNumbers[i]) return true;
        if (latestNumbers[i] < currentNumbers[i]) return false;
      }

      if (latestStage > currentStage) return true;
      if (latestStage < currentStage) return false;

      return latestStageNumber > currentStageNumber;
    } catch (_) {
      return false;
    }
  }

  List<dynamic> _parseVersion(String version) {
    final stagePriority = {
      "debug": 0,
      "alpha": 1,
      "beta": 2,
      "rc": 3, // release candidate
      "": 4, // stable
    };

    final split = version.split('-');
    final numbers = split[0].split('.').map(int.parse).toList();

    while (numbers.length < 3) {
      numbers.add(0);
    }

    String stageName = "";
    int stageNumber = 0;

    if (split.length > 1) {
      final stageParts = split[1].split('.');
      stageName = stageParts[0].toLowerCase();

      if (stageParts.length > 1) {
        stageNumber = int.tryParse(stageParts[1]) ?? 0;
      }
    }

    final stage = stagePriority[stageName] ?? -1;

    return [numbers, stage, stageNumber];
  }
}
