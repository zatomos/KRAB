import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Reclaims space in the temporary directory that nothing else owns.
class StorageCleanup {
  static const _downloadedApk = 'app_update.apk';

  /// Directories under the temporary directory that manage their own contents.
  static const _managed = {
    'image_cache', // ImageDiskCache
    'libCachedImageData', // cached_network_image's own cache manager
    'data',
  };

  /// Files the notification code prunes on its own schedule
  static const _notifPrefix = 'notif_img_';

  /// Anything left behind by the image picker or the cropper.
  static const _leftoverMaxAge = Duration(days: 7);

  /// How long a downloaded APK is spared for.
  static const _apkGracePeriod = Duration(minutes: 10);

  static Future<Directory> Function() _tempDir = getTemporaryDirectory;

  @visibleForTesting
  static void overrideForTest({Future<Directory> Function()? tempDir}) {
    if (tempDir != null) _tempDir = tempDir;
  }

  /// Best-effort: every failure is a file we try again for on the next launch.
  static Future<void> sweep() async {
    try {
      final tmp = await _tempDir();
      var freed = 0;

      final apk = File('${tmp.path}/$_downloadedApk');
      freed += await _deleteIfStale(
          apk, DateTime.now().subtract(_apkGracePeriod),
          label: 'the downloaded update');

      final cutoff = DateTime.now().subtract(_leftoverMaxAge);
      await for (final entity in tmp.list(followLinks: false)) {
        final name = entity.uri.pathSegments
            .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (entity is Directory) {
          if (_managed.contains(name)) continue;
          freed += await _sweepDir(entity, cutoff);
        } else if (entity is File) {
          if (name.startsWith(_notifPrefix)) continue;
          freed += await _deleteIfStale(entity, cutoff);
        }
      }

      if (freed > 0) {
        debugPrint('[cleanup] freed ${(freed / 1024 / 1024).toStringAsFixed(1)} MB');
      }
    } catch (e) {
      debugPrint('[cleanup] sweep failed: $e');
    }
  }

  /// Deletes the stale files in dir, and dir itself once it is empty.
  static Future<int> _sweepDir(Directory dir, DateTime cutoff) async {
    var freed = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          freed += await _deleteIfStale(entity, cutoff);
        } else if (entity is Directory) {
          freed += await _sweepDir(entity, cutoff);
        }
      }
      if (await dir.list().isEmpty) await dir.delete();
    } catch (_) {
      // Best-effort.
    }
    return freed;
  }

  /// Deletes the file if it was last touched before cutoff.
  static Future<int> _deleteIfStale(File file, DateTime cutoff,
      {String? label}) async {
    try {
      if (!await file.exists()) return 0;
      final stat = await file.stat();
      if (stat.modified.isAfter(cutoff)) return 0;
      await file.delete();
      if (label != null) debugPrint('[cleanup] removed $label');
      return stat.size;
    } catch (_) {
      return 0;
    }
  }
}
