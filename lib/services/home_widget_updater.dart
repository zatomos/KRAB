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

/// Schedule or cancel the periodic background widget refresh.
///
/// On app start, call without [force] so an already-scheduled worker is kept as
/// is. Otherwise re-registering on every launch resets the interval timer and
/// cancels any in-flight run, which makes background updates unreliable. Pass
/// [force] only when the user actually changes the interval, so the new period
/// takes effect.
Future<void> scheduleWidgetRefresh(int minutes, {bool force = false}) async {
  if (minutes <= 0) {
    await Workmanager().cancelByUniqueName('widget_periodic_refresh');
    return;
  }
  await Workmanager().registerPeriodicTask(
    'widget_periodic_refresh',
    'widgetPeriodicRefresh',
    frequency: Duration(minutes: minutes),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: force
        ? ExistingPeriodicWorkPolicy.replace
        : ExistingPeriodicWorkPolicy.keep,
  );
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
      debugPrint("Registry empty, triggering onUpdate to force syncRegistry.");
      await DebugNotifier.instance.notifyWidgetStep(2, 3, "Registry empty, syncing");
      await HomeWidget.updateWidget(name: "HomeScreenWidget");
      await HomeWidget.updateWidget(name: "HomeScreenWidgetMulti");
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
    bool anyNewImage = false;

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

      final result = await _syncWidget(entry, images, dir);
      if (result.newImage) anyNewImage = true;
      if (result.changed) {
        if (entry.isMulti) {
          multiChanged = true;
        } else {
          singleChanged = true;
        }
      }
    }

    final anyChanged = singleChanged || multiChanged;
    final String step2Message;
    if (anyNewImage) {
      step2Message = "New images found";
    } else if (anyChanged) {
      step2Message = "Reloaded (new group filter or repaired missing thumbnail)";
    } else {
      step2Message = "No new images";
    }
    await DebugNotifier.instance.notifyWidgetStep(2, 3, step2Message);

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

/// Sync a single widget instance.
Future<({bool changed, bool newImage})> _syncWidget(
    _WidgetEntry entry, List<dynamic> images, Directory dir) async {
  if (images.isEmpty) return (changed: false, newImage: false);

  final id = entry.id;
  final latestId = images[0]['id']?.toString();
  if (latestId == null) return (changed: false, newImage: false);

  final lastId = await HomeWidget.getWidgetData<String>('lastImageId_$id');
  bool changed = false;
  bool newImage = false;

  if (latestId != lastId) {
    // New main image for this widget. Previous-image slots are reconciled by
    // id in _ensurePrevImages below, so there is no fragile file rotation here.
    final imgResult = await getImage(latestId);
    final bytes = imgResult.data;
    if (bytes == null) {
      debugPrint("Widget $id: main image download failed");
      return (changed: false, newImage: false);
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
    newImage = lastId != null;

    // Auto-save the original image to the gallery
    await _maybeAutoSave(latestId, bytes, uploaderName);
  }

  // Ensure previous images and pfps are present
  if (entry.isMulti) {
    final repaired = await _ensurePrevImages(entry, images, dir);
    changed = changed || repaired;
  }

  return (changed: changed, newImage: newImage);
}

/// Reconcile each previous-image slot so it matches images[i], by id.
///
/// A slot is re-fetched whenever the id stored for it differs from the desired
/// image or its file is missing, so the result is idempotent and self-correcting
/// regardless of how many images arrived between refreshes or whether an earlier
/// run failed midway. Slots with no corresponding image are cleared so a stale
/// image can never linger or be duplicated.
Future<bool> _ensurePrevImages(_WidgetEntry entry, List<dynamic> images, Directory dir) async {
  final id = entry.id;
  bool changed = false;

  for (int i = 1; i <= 2; i++) {
    final imgFile = File(_prevPath(dir, id, i));
    final pfpFile = File(_prevPfpPath(dir, id, i));
    final idKey = 'previousImage${i}Id_$id';
    final urlKey = 'previousImage${i}Url_$id';
    final pfpKey = 'previousImage${i}SenderPfpUrl_$id';

    // No image for this slot (fewer than 3 images available): clear it.
    if (i >= images.length || images[i]['id'] == null) {
      if (await imgFile.exists()) await imgFile.delete();
      if (await pfpFile.exists()) await pfpFile.delete();
      await HomeWidget.saveWidgetData(urlKey, '');
      await HomeWidget.saveWidgetData(pfpKey, '');
      await HomeWidget.saveWidgetData(idKey, '');
      continue;
    }

    final prevId = images[i]['id'].toString();
    final storedId = await HomeWidget.getWidgetData<String>(idKey);

    if (storedId != prevId || !await imgFile.exists()) {
      final result = await getImage(prevId, lowRes: true);
      if (result.success && result.data != null) {
        await imgFile.writeAsBytes(result.data!, flush: true);
        await HomeWidget.saveWidgetData(urlKey, imgFile.path);
        await HomeWidget.saveWidgetData(idKey, prevId);
        changed = true;
        // The uploader may have changed, so refresh the pfp too.
        if (await _savePrevPfp(prevId, pfpFile, pfpKey)) changed = true;
      }
    } else if (!await pfpFile.exists()) {
      // Image already correct but pfp missing — repair just the pfp.
      if (await _savePrevPfp(prevId, pfpFile, pfpKey)) changed = true;
    }
  }

  return changed;
}

/// Fetch and store the uploader's pfp for a previous image. Returns true if a
/// file was written.
Future<bool> _savePrevPfp(String prevId, File pfpFile, String pfpKey) async {
  try {
    final details = await getImageDetails(prevId);
    final uploaderId = details.data?['uploaded_by']?.toString();
    if (uploaderId == null) return false;
    final result = await getProfilePictureBytes(uploaderId);
    if (result.success && result.data != null) {
      await pfpFile.writeAsBytes(result.data!, flush: true);
      await HomeWidget.saveWidgetData(pfpKey, pfpFile.path);
      return true;
    }
  } catch (e) {
    debugPrint("Widget: prev pfp save failed: $e");
  }
  return false;
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
