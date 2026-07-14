import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import 'package:krab/config.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/services/notification_channels.dart';

/// A single published GitHub release.
class Release {
  final String version;
  final String downloadUrl;
  final List<String> changelog;

  Release({
    required this.version,
    required this.downloadUrl,
    required this.changelog,
  });

  /// Builds a release from one entry of GitHub releases`.
  static Release? fromGitHub(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    // Check for version validity
    if (version.isEmpty || !RegExp(r'^\d').hasMatch(version)) return null;

    final assets = json['assets'];
    if (assets is! List) return null;

    String? apkUrl;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'] as String? ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        apkUrl = asset['browser_download_url'] as String?;
        break;
      }
    }
    if (apkUrl == null || apkUrl.isEmpty) return null;

    final changelog = (json['body'] as String? ?? '')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        // Strip Markdown bullets
        .map((l) => l.startsWith('- ') || l.startsWith('* ')
            ? l.substring(2).trim()
            : l)
        .toList();

    return Release(
      version: version,
      downloadUrl: apkUrl,
      changelog: changelog,
    );
  }
}

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final List<Release> releases;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releases,
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

  /// Which repository this build updates from, and whether it looks at all.
  bool get isEnabled => enableAutoUpdate && updateRepo.isNotEmpty;

  String get _releasesUrl =>
      'https://api.github.com/repos/$updateRepo/releases?per_page=30';

  /// Never checks when this build has no repo to update from, or has updates
  /// switched off
  Future<UpdateCheckResult> checkForUpdate() async {
    if (!isEnabled) {
      debugPrint('Update check skipped: not enabled in config.dart');
      return UpdateCheckResult(success: false, hasUpdate: false);
    }

    try {
      final response = await _dio.get(
        _releasesUrl,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
          // Inspect the status
          validateStatus: (_) => true,
        ),
      );

      final status = response.statusCode ?? 0;

      // Unauthenticated GitHub API calls are limited
      if (status == 403 || status == 429) {
        debugPrint('Update check rate-limited by GitHub (status $status)');
        return UpdateCheckResult(success: false, hasUpdate: false);
      }
      if (status != 200) {
        debugPrint('Update check failed (status $status)');
        return UpdateCheckResult(success: false, hasUpdate: false);
      }

      dynamic rawData = response.data;
      if (rawData is String) rawData = jsonDecode(rawData);

      final releases = _parseReleases(rawData);
      if (releases.isEmpty) {
        return UpdateCheckResult(success: true, hasUpdate: false);
      }

      // Newest release is the install target
      releases.sort((a, b) => compareVersions(a.version, b.version));
      final latest = releases.last;

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final hasUpdate = compareVersions(currentVersion, latest.version) < 0;
      if (!hasUpdate) {
        return UpdateCheckResult(success: true, hasUpdate: false);
      }

      // Releases newer than the user's version, newest first
      final newer = releases
          .where((r) => compareVersions(currentVersion, r.version) < 0)
          .toList()
          .reversed
          .toList();

      return UpdateCheckResult(
        success: true,
        hasUpdate: true,
        info: UpdateInfo(
          version: latest.version,
          downloadUrl: latest.downloadUrl,
          releases: newer,
        ),
      );
    } catch (e) {
      debugPrint('Error checking for updates: $e');
      return UpdateCheckResult(success: false, hasUpdate: false);
    }
  }

  /// Parses the JSON array returned by the release.
  List<Release> _parseReleases(dynamic data) {
    if (data is! List) return [];
    return data
        .whereType<Map<String, dynamic>>()
        .where((e) => e['draft'] != true && e['prerelease'] != true)
        .map(Release.fromGitHub)
        .whereType<Release>()
        .where((r) => r.version.isNotEmpty)
        .toList();
  }

  Future<bool> downloadAndInstall(
    String downloadUrl,
    Function(double) onProgress,
  ) async {
    try {
      // Cache dir maps
      final dir = await getTemporaryDirectory();
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
      // Hand the APK to the system package installer
      const channel = MethodChannel('krab/installer');
      final launched =
          await channel.invokeMethod<bool>('installApk', {'path': savePath}) ??
              false;
      debugPrint('Installer launched: $launched');
      return launched;
    } catch (e) {
      debugPrint('Error during install: $e');
      return false;
    }
  }

  /// Returns < 0 if [a] is older than [b], 0 if equal, > 0 if newer.
  @visibleForTesting
  int compareVersions(String a, String b) {
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

    final result = await service.checkForUpdate();
    if (!result.success) return;

    await UserPreferences.setLastUpdateCheckMillis(now);

    if (!result.hasUpdate || result.info == null) return;

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
    final numbers =
        split[0].split('.').map((n) => int.tryParse(n.trim()) ?? 0).toList();
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
