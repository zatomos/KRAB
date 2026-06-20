import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:android_package_installer/android_package_installer.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:krab/user_preferences.dart';
import 'package:krab/services/notification_channels.dart';

/// A single published release entry in the manifest.
class Release {
  final String version;
  final String downloadUrl;
  final List<String> changelog;
  final bool mandatory;

  Release({
    required this.version,
    required this.downloadUrl,
    required this.changelog,
    this.mandatory = false,
  });

  factory Release.fromJson(Map<String, dynamic> json) {
    return Release(
      version: json['version'] ?? '',
      downloadUrl: json['downloadUrl'] ?? '',
      changelog: List<String>.from(json['changelog'] ?? []),
      mandatory: json['mandatory'] ?? false,
    );
  }
}

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final List<Release> releases;
  final bool forceUpdate;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releases,
    this.forceUpdate = false,
  });
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

      final releases = _parseReleases(rawData);
      if (releases.isEmpty) {
        return UpdateCheckResult(success: true, hasUpdate: false);
      }

      // Newest release is the install target
      releases.sort((a, b) => _compareVersions(a.version, b.version));
      final latest = releases.last;

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final hasUpdate = _compareVersions(currentVersion, latest.version) < 0;
      if (!hasUpdate) {
        return UpdateCheckResult(success: true, hasUpdate: false);
      }

      // Releases newer than the user's version, newest first
      final newer = releases
          .where((r) => _compareVersions(currentVersion, r.version) < 0)
          .toList()
          .reversed
          .toList();

      // Forced if the user has skipped past any mandatory release
      final forceUpdate = newer.any((r) => r.mandatory);

      return UpdateCheckResult(
        success: true,
        hasUpdate: true,
        info: UpdateInfo(
          version: latest.version,
          downloadUrl: latest.downloadUrl,
          releases: newer,
          forceUpdate: forceUpdate,
        ),
      );
    } catch (e) {
      debugPrint('Error checking for updates: $e');
      return UpdateCheckResult(success: false, hasUpdate: false);
    }
  }

  /// Parses the `{"releases": [...]}` manifest.
  List<Release> _parseReleases(Map<String, dynamic> data) {
    if (data['releases'] is! List) return [];
    return (data['releases'] as List)
        .map((e) => Release.fromJson(e as Map<String, dynamic>))
        .where((r) => r.version.isNotEmpty)
        .toList();
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

  /// Returns < 0 if [a] is older than [b], 0 if equal, > 0 if newer.
  /// Throws on unparseable input so callers can decide how to handle it.
  int _compareVersions(String a, String b) {
    final pa = _parseVersion(a);
    final pb = _parseVersion(b);

    for (int i = 0; i < 3; i++) {
      if (pa.nums[i] != pb.nums[i]) return pa.nums[i] - pb.nums[i];
    }
    if (pa.stage != pb.stage) return pa.stage - pb.stage;
    return pa.stageNum - pb.stageNum;
  }

  static const _checkThrottle = Duration(hours: 24);

  /// Background update check, meant to piggyback on the periodic widget-refresh
  /// wakeup so it adds no extra alarms. Throttled to at most once per
  /// checkThrottle
  static Future<void> maybeCheckAndNotifyUpdate() async {
    final service = UpdateService();
    if (!service.isEnabled) return;
    if (!UserPreferences.updateNotifications) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final last = UserPreferences.getLastUpdateCheckMillis();
    if (now - last < _checkThrottle.inMilliseconds) return;
    await UserPreferences.setLastUpdateCheckMillis(now);

    final result = await service.checkForUpdate();
    if (!result.success || !result.hasUpdate || result.info == null) return;

    await showUpdateNotification(result.info!.version);
  }

  /// Parsed version: release numbers (major/minor/patch), prerelease [stage]
  /// priority, and the number within that stage (e.g. beta.2 -> 2).
  ({List<int> nums, int stage, int stageNum}) _parseVersion(String version) {
    const stagePriority = {
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

    return (
      nums: numbers,
      stage: stagePriority[stageName] ?? -1,
      stageNum: stageNumber,
    );
  }
}
