import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/user_preferences.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/services/debug_notifier.dart';
import 'file_saver.dart';

// Registry keys written by the Kotlin widget providers
// CSV of widget ids
const _registrySingleKey = 'widgetRegistrySingle';
const _registryMultiKey = 'widgetRegistryMulti';

/// A widget instance to update
class _WidgetEntry {
  final int id;
  final bool isMulti;
  final List<String> groupIds; // empty = all groups

  _WidgetEntry(this.id, this.isMulti, this.groupIds);

  /// Signature used to dedupe network fetches across widgets sharing a filter.
  String get filterKey => groupIds.isEmpty ? '*' : (List.of(groupIds)..sort()).join(',');
}

/// Cache the user's groups so the native widget configure activity can populate
/// its group filter without a network call.
Future<void> cacheUserGroupsForWidget() async {
  try {
    final result = await getUserGroups();
    if (!result.success || result.data == null) return;
    final list = result.data!
        .map((g) => {'id': g.id, 'name': g.name})
        .toList();
    await HomeWidget.saveWidgetData('cachedGroups', jsonEncode(list));
    debugPrint("Widget: cached ${list.length} groups");
  } catch (e) {
    debugPrint("Widget: cache groups failed: $e");
  }
}

Future<void> scheduleWidgetRefresh(int minutes) async {
  await Workmanager().cancelByUniqueName('widget_periodic_refresh');
  if (minutes > 0) {
    await Workmanager().registerPeriodicTask(
      'widget_periodic_refresh',
      'widgetPeriodicRefresh',
      frequency: Duration(minutes: minutes),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
  }
}

Future<List<int>> _readRegistry(String key) async {
  final csv = await HomeWidget.getWidgetData<String>(key);
  if (csv == null || csv.trim().isEmpty) return [];
  return csv
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .toList();
}

Future<List<String>> _readWidgetGroups(int id) async {
  final csv = await HomeWidget.getWidgetData<String>('widgetGroups_$id');
  if (csv == null || csv.trim().isEmpty) return [];
  return csv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

Future<void> updateHomeWidget() async {
  try {
    debugPrint("Starting widget update process");
    await DebugNotifier.instance.notifyWidgetUpdateStarted();

    // Build the list of widget instances to update
    final singleIds = await _readRegistry(_registrySingleKey);
    final multiIds = await _readRegistry(_registryMultiKey);

    final entries = <_WidgetEntry>[];
    for (final id in singleIds) {
      entries.add(_WidgetEntry(id, false, await _readWidgetGroups(id)));
    }
    for (final id in multiIds) {
      entries.add(_WidgetEntry(id, true, await _readWidgetGroups(id)));
    }

    if (entries.isEmpty) {
      debugPrint("Registry empty, skipping update.");
      await DebugNotifier.instance.notifyWidgetStep(2, 3, "Registry empty");
      return;
    }
    debugPrint("Updating ${entries.length} widget(s) "
        "(single=${singleIds.length} multi=${multiIds.length})");

    final dir = await getApplicationSupportDirectory();

    // Cache image-list fetches by filter signature so widgets that share a
    // group filter only hit the network once.
    final fetchCache = <String, List<dynamic>>{};

    bool singleChanged = false;
    bool multiChanged = false;

    for (final entry in entries) {
      // A multi widget needs 3 images, single needs 1
      final needed = entry.isMulti ? 3 : 1;
      final cacheKey = "${entry.filterKey}#$needed";

      List<dynamic>? images = fetchCache[cacheKey];
      if (images == null) {
        final result = await getLatestImages(needed, groupIds: entry.groupIds);
        if (!result.success || result.data == null) {
          debugPrint("Widget ${entry.id}: fetch failed: ${result.error}");
          await DebugNotifier.instance.notifyWidgetUpdateFailed("Fetch failed: ${result.error}");
          continue;
        }
        images = result.data!;
        fetchCache[cacheKey] = images;
      }

      final changed = await _syncWidget(entry, images, dir);
      if (changed) {
        if (entry.isMulti) {
          multiChanged = true;
        } else {
          singleChanged = true;
        }
      }
    }

    final anyChanged = singleChanged || multiChanged;
    await DebugNotifier.instance.notifyWidgetStep(2, 3, anyChanged ? "New images found" : "No new images");

    if (singleChanged) await HomeWidget.updateWidget(name: "HomeScreenWidget");
    if (multiChanged) await HomeWidget.updateWidget(name: "HomeScreenWidgetMulti");

    debugPrint("Widget update complete (single=$singleChanged multi=$multiChanged).");
    await DebugNotifier.instance.notifyWidgetUpdateSuccess(anyChanged ? "updated" : "unchanged");
  } catch (e, st) {
    debugPrint("Widget update failed: $e\n$st");
    await DebugNotifier.instance.notifyWidgetUpdateFailed("Error: $e");
  }
}

// ---- Per-widget paths and keys -------------------------------------------

String _mainPath(Directory dir, int id) => "${dir.path}/krab_widget_${id}_current.jpg";
String _prevPath(Directory dir, int id, int i) => "${dir.path}/krab_widget_${id}_prev$i.jpg";
String _pfpPath(Directory dir, int id) => "${dir.path}/krab_widget_${id}_pfp.jpg";
String _prevPfpPath(Directory dir, int id, int i) => "${dir.path}/krab_widget_${id}_prev${i}_pfp.jpg";

/// Sync a single widget instance. Returns true if anything changed
Future<bool> _syncWidget(_WidgetEntry entry, List<dynamic> images, Directory dir) async {
  if (images.isEmpty) return false;

  final id = entry.id;
  final latestId = images[0]['id']?.toString();
  if (latestId == null) return false;

  final lastId = await HomeWidget.getWidgetData<String>('lastImageId_$id');
  bool changed = false;

  if (latestId != lastId) {
    // New main image for this widget.
    if (entry.isMulti) {
      if (lastId == null) {
        // Filter changed or first load: wipe stale prev files so that we
        // refetch them from the new group filter instead of rotating old ones
        await _clearPrevFiles(dir, id);
      } else {
        await _rotatePrevFiles(dir, id);
      }
    }

    final imgResult = await getImage(latestId);
    final bytes = imgResult.data;
    if (bytes == null) {
      debugPrint("Widget $id: main image download failed");
      return false;
    }
    final mainPath = _mainPath(dir, id);
    await File(mainPath).writeAsBytes(bytes, flush: true);
    await HomeWidget.saveWidgetData('recentImageUrl_$id', mainPath);

    final details = await getImageDetails(latestId);
    final description = details.data?['description'] ?? "";
    final uploaderId = details.data?['uploaded_by'];
    final uploaderName = (await getUserDetails(uploaderId)).data?.username ?? "Unknown";
    await HomeWidget.saveWidgetData('recentImageDescription_$id', description);
    await HomeWidget.saveWidgetData('recentImageSender_$id', uploaderName);
    await HomeWidget.saveWidgetData('recentSenderUserId_$id', uploaderId);

    try {
      if (uploaderId != null) {
        final pfp = await getProfilePictureBytes(uploaderId);
        if (pfp.success && pfp.data != null) {
          final p = _pfpPath(dir, id);
          await File(p).writeAsBytes(pfp.data!, flush: true);
          await HomeWidget.saveWidgetData('recentSenderPfpUrl_$id', p);
        }
      }
    } catch (e) {
      debugPrint("Widget $id: pfp save failed: $e");
    }

    await HomeWidget.saveWidgetData('lastImageId_$id', latestId);
    changed = true;

    // Auto-save the original image to the gallery
    await _maybeAutoSave(latestId, bytes, uploaderName);
  }

  // Ensure previous images and pfps are present
  if (entry.isMulti) {
    final repaired = await _ensurePrevImages(entry, images, dir);
    changed = changed || repaired;
  }

  return changed;
}

/// Delete prev image/pfp files for a multi widget so that we re-download them
Future<void> _clearPrevFiles(Directory dir, int id) async {
  try {
    for (int i = 1; i <= 2; i++) {
      final img = File(_prevPath(dir, id, i));
      final pfp = File(_prevPfpPath(dir, id, i));
      if (await img.exists()) await img.delete();
      if (await pfp.exists()) await pfp.delete();
    }
  } catch (e) {
    debugPrint("Widget $id: clear prev files failed: $e");
  }
}

/// Rotate this widget's on-disk files before saving a new main image
Future<void> _rotatePrevFiles(Directory dir, int id) async {
  try {
    final current = File(_mainPath(dir, id));
    final prev1 = File(_prevPath(dir, id, 1));
    final prev2 = File(_prevPath(dir, id, 2));
    final pfp = File(_pfpPath(dir, id));
    final prev1Pfp = File(_prevPfpPath(dir, id, 1));
    final prev2Pfp = File(_prevPfpPath(dir, id, 2));

    if (await prev1.exists()) await prev1.copy(prev2.path);
    if (await current.exists()) await current.copy(prev1.path);
    if (await prev1Pfp.exists()) await prev1Pfp.copy(prev2Pfp.path);
    if (await pfp.exists()) await pfp.copy(prev1Pfp.path);

    // Register fixed paths so the widget knows where to look
    await HomeWidget.saveWidgetData('previousImage1Url_$id', prev1.path);
    await HomeWidget.saveWidgetData('previousImage2Url_$id', prev2.path);
    await HomeWidget.saveWidgetData('previousImage1SenderPfpUrl_$id', prev1Pfp.path);
    await HomeWidget.saveWidgetData('previousImage2SenderPfpUrl_$id', prev2Pfp.path);
  } catch (e) {
    debugPrint("Widget $id: file rotation failed: $e");
  }
}

/// Fetch any missing previous images or pfps for a multi widget
Future<bool> _ensurePrevImages(_WidgetEntry entry, List<dynamic> images, Directory dir) async {
  final id = entry.id;
  bool changed = false;

  for (int i = 1; i <= 2; i++) {
    if (i >= images.length) break;
    final prevId = images[i]['id']?.toString();
    if (prevId == null) continue;

    final imgFile = File(_prevPath(dir, id, i));
    if (!await imgFile.exists()) {
      final result = await getImage(prevId, lowRes: true);
      if (result.success && result.data != null) {
        await imgFile.writeAsBytes(result.data!, flush: true);
        await HomeWidget.saveWidgetData('previousImage${i}Url_$id', imgFile.path);
        changed = true;
      }
    }

    final pfpFile = File(_prevPfpPath(dir, id, i));
    if (!await pfpFile.exists()) {
      try {
        final details = await getImageDetails(prevId);
        final uploaderId = details.data?['uploaded_by']?.toString();
        if (uploaderId != null) {
          final result = await getProfilePictureBytes(uploaderId);
          if (result.success && result.data != null) {
            await pfpFile.writeAsBytes(result.data!, flush: true);
            await HomeWidget.saveWidgetData('previousImage${i}SenderPfpUrl_$id', pfpFile.path);
            changed = true;
          }
        }
      } catch (e) {
        debugPrint("Widget $id: prev$i pfp repair failed: $e");
      }
    }
  }

  return changed;
}

/// Auto-save the newest received image to the gallery, at most once per image
/// id across all widgets, when the user has the setting enabled.
Future<void> _maybeAutoSave(String imageId, Uint8List bytes, String uploaderName) async {
  try {
    if (!await UserPreferences.getAutoImageSave()) return;
    final lastSaved = await UserPreferences.getLastWidgetImageId();
    if (imageId == lastSaved) return;
    await downloadImage(bytes, uploaderName, DateTime.now().toIso8601String());
    await UserPreferences.setLastWidgetImageId(imageId);
  } catch (e) {
    debugPrint("Widget: auto-save failed: $e");
  }
}
