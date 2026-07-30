import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/user_preferences.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/debug_notifier.dart';
import 'file_saver.dart';

// Registry keys written by the Kotlin widget providers
// CSV of widget ids
const _registrySingleKey = 'widgetRegistrySingle';
const _registryMultiKey = 'widgetRegistryMulti';

/// Read by the Kotlin providers to draw the signed-out state.
const _signedOutKey = 'widgetSignedOut';

/// Settle whether the widgets show the signed-out state. True when signed in.
Future<bool> refreshWidgetAuthState() async {
  // Signed in anywhere is signed in: the widget draws its signed-out state only
  // when there is nothing at all to show.
  var signedIn = false;
  for (final instance in InstanceRegistry.instance.all) {
    if (await instance.auth.hasStoredSession()) {
      signedIn = true;
      break;
    }
  }
  await _setWidgetSignedOut(!signedIn);
  return signedIn;
}

Future<void> _setWidgetSignedOut(bool signedOut) async {
  final previous = await HomeWidget.getWidgetData<bool>(_signedOutKey);
  await HomeWidget.saveWidgetData(_signedOutKey, signedOut);
  if (previous == signedOut) return;
  debugPrint('Widget: signed-out state -> $signedOut');
  await HomeWidget.updateWidget(name: 'HomeScreenWidget');
  await HomeWidget.updateWidget(name: 'HomeScreenWidgetMulti');
}

/// A widget instance to update
class _WidgetEntry {
  final int id;
  final bool isMulti;
  final List<String> groupIds; // empty = all groups

  _WidgetEntry(this.id, this.isMulti, this.groupIds);

  /// Signature used to dedupe network fetches across widgets sharing a filter.
  String get filterKey =>
      groupIds.isEmpty ? '*' : (List.of(groupIds)..sort()).join(',');
}

/// How a group is named in the widget's filter.
String widgetGroupKey(String instanceId, String groupId) =>
    '$instanceId/$groupId';

/// Split a filter entry back into the instance it names and the group on it.
({String? instanceId, String groupId}) parseWidgetGroupKey(String key) {
  final slash = key.indexOf('/');
  if (slash < 0) return (instanceId: null, groupId: key);
  return (
    instanceId: key.substring(0, slash),
    groupId: key.substring(slash + 1),
  );
}

/// Cache the user's groups so the native widget configure activity can populate
/// its group filter without a network call.
Future<void> cacheUserGroupsForWidget() async {
  try {
    final sources =
        InstanceRegistry.instance.all.where((i) => i.auth.isLoggedIn).toList();
    if (sources.isEmpty) return;

    final responses =
        await Future.wait(sources.map((i) => i.api.getUserGroups().orGiveUp()));

    final list = <Map<String, String>>[];
    for (var i = 0; i < sources.length; i++) {
      final result = responses[i];
      if (!result.success || result.data == null) continue;
      for (final group in result.data!) {
        list.add({
          'id': widgetGroupKey(sources[i].id, group.id),
          'name': sources.length > 1
              ? '${group.name} · ${sources[i].label}'
              : group.name,
        });
      }
    }
    if (list.isEmpty) return;

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
  return csv
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

Future<void> updateHomeWidget() async {
  try {
    if (!await refreshWidgetAuthState()) {
      debugPrint("Widget: no session, showing the signed-out state");
      return;
    }

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
      await DebugNotifier.instance
          .notifyWidgetStep(2, 3, "Registry empty, syncing");
      await HomeWidget.updateWidget(name: "HomeScreenWidget");
      await HomeWidget.updateWidget(name: "HomeScreenWidgetMulti");
      return;
    }
    debugPrint("Updating ${entries.length} widget(s) "
        "(single=${singleIds.length} multi=${multiIds.length})");

    final dir = await getApplicationSupportDirectory();

    // Cache image-list fetches by filter signature so widgets that share a
    // group filter only hit the network once.
    final fetchCache = <String, List<ImageRef>>{};

    bool singleChanged = false;
    bool multiChanged = false;
    bool anyNewImage = false;

    for (final entry in entries) {
      // A multi widget needs 3 images, single needs 1
      final needed = entry.isMulti ? 3 : 1;
      final cacheKey = "${entry.filterKey}#$needed";

      List<ImageRef>? images = fetchCache[cacheKey];
      if (images == null) {
        images = await _latestAcross(needed, entry.groupIds);
        if (images == null) {
          debugPrint("Widget ${entry.id}: fetch failed");
          await DebugNotifier.instance.notifyWidgetUpdateFailed("Fetch failed");
          continue;
        }
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
      step2Message =
          "Reloaded (new group filter or repaired missing thumbnail)";
    } else {
      step2Message = "No new images";
    }
    await DebugNotifier.instance.notifyWidgetStep(2, 3, step2Message);

    if (singleChanged) {
      await HomeWidget.updateWidget(name: "HomeScreenWidget");
    }
    if (multiChanged) {
      await HomeWidget.updateWidget(name: "HomeScreenWidgetMulti");
    }

    debugPrint(
        "Widget update complete (single=$singleChanged multi=$multiChanged).");
    await DebugNotifier.instance
        .notifyWidgetUpdateSuccess(anyChanged ? "updated" : "unchanged");
  } catch (e, st) {
    debugPrint("Widget update failed: $e\n$st");
    await DebugNotifier.instance.notifyWidgetUpdateFailed("Error: $e");
  }
}

// ---- Per-widget paths and keys -------------------------------------------

String _mainPath(Directory dir, int id) =>
    "${dir.path}/krab_widget_${id}_current.jpg";
String _prevPath(Directory dir, int id, int i) =>
    "${dir.path}/krab_widget_${id}_prev$i.jpg";
String _pfpPath(Directory dir, int id) =>
    "${dir.path}/krab_widget_${id}_pfp.jpg";
String _prevPfpPath(Directory dir, int id, int i) =>
    "${dir.path}/krab_widget_${id}_prev${i}_pfp.jpg";

/// The newest photos across every signed-in server.
/// Returns null only when nothing could be reached at all.
Future<List<ImageRef>?> _latestAcross(int needed, List<String> groupIds) async {
  final registry = InstanceRegistry.instance;

  // An empty filter means every group on every server.
  final wanted = <String, List<String>>{};
  for (final key in groupIds) {
    final parsed = parseWidgetGroupKey(key);
    final instanceId = parsed.instanceId ?? registry.all.firstOrNull?.id;
    if (instanceId == null) continue;
    (wanted[instanceId] ??= []).add(parsed.groupId);
  }

  final sources = registry.all
      .where((i) =>
          i.auth.isLoggedIn && (groupIds.isEmpty || wanted.containsKey(i.id)))
      .toList();
  if (sources.isEmpty) return null;

  final results = await Future.wait(sources.map((instance) => instance.api
      .getLatestImages(needed, groupIds: wanted[instance.id])
      .orGiveUp()));

  final refs = <ImageRef>[];
  var anySucceeded = false;
  for (var i = 0; i < results.length; i++) {
    final result = results[i];
    if (!result.success || result.data == null) {
      debugPrint('Widget: ${sources[i].id} fetch failed (${result.error})');
      continue;
    }
    anySucceeded = true;
    refs.addAll(result.data!);
  }
  if (!anySucceeded) return null;

  // One photo sent to several servers should fill one slot
  final merged =
      mergeImages(refs, instanceOrder: [for (final i in sources) i.id]);
  sortImagesNewestFirst(merged);
  return [for (final photo in merged.take(needed)) photo.primary];
}

/// The API of the server holding a photo, or null once that server is gone.
KrabApi? _apiFor(ImageRef ref) =>
    InstanceRegistry.instance.byId(ref.instanceId)?.api;

/// How a shown photo is recorded
String _photoKey(ImageRef ref) => '${ref.instanceId}/${ref.id}';

/// Sync a single widget instance.
Future<({bool changed, bool newImage})> _syncWidget(
    _WidgetEntry entry, List<ImageRef> images, Directory dir) async {
  if (images.isEmpty) return (changed: false, newImage: false);

  final id = entry.id;
  final latest = images[0];
  final latestId = _photoKey(latest);
  final api = _apiFor(latest);
  if (api == null) return (changed: false, newImage: false);

  final lastId = await HomeWidget.getWidgetData<String>('lastImageId_$id');
  // TODO: remove later, along with the rest of the single-instance migration.
  final showing = lastId == latestId || lastId == latest.id;
  bool changed = false;
  bool newImage = false;

  if (!showing) {
    // New main image for this widget. Previous-image slots are reconciled by
    // id in _ensurePrevImages below, so there is no fragile file rotation here.
    final imgResult = await api.getImage(latest.id);
    final bytes = imgResult.data;
    if (bytes == null) {
      debugPrint("Widget $id: main image download failed");
      return (changed: false, newImage: false);
    }
    final mainPath = _mainPath(dir, id);
    await File(mainPath).writeAsBytes(bytes, flush: true);
    await HomeWidget.saveWidgetData('recentImageUrl_$id', mainPath);

    final details = await api.getImageDetails(latest.id);
    final description = details.data?.description ?? "";
    final uploaderId = details.data?.uploadedBy;
    final uploaderName = uploaderId == null
        ? "Unknown"
        : (await api.getUserDetails(uploaderId)).data?.username ?? "Unknown";
    await HomeWidget.saveWidgetData('recentImageDescription_$id', description);
    await HomeWidget.saveWidgetData('recentImageSender_$id', uploaderName);
    await HomeWidget.saveWidgetData('recentSenderUserId_$id', uploaderId);

    try {
      if (uploaderId != null) {
        final pfpFile = File(_pfpPath(dir, id));
        final pfp = await api.getProfilePictureBytes(uploaderId);
        if (pfp.success && pfp.data != null) {
          await pfpFile.writeAsBytes(pfp.data!, flush: true);
          await HomeWidget.saveWidgetData(
              'recentSenderPfpUrl_$id', pfpFile.path);
        } else {
          // No pfp: clear the path
          if (await pfpFile.exists()) await pfpFile.delete();
          await HomeWidget.saveWidgetData('recentSenderPfpUrl_$id', '');
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
Future<bool> _ensurePrevImages(
    _WidgetEntry entry, List<ImageRef> images, Directory dir) async {
  final id = entry.id;
  bool changed = false;

  for (int i = 1; i <= 2; i++) {
    final imgFile = File(_prevPath(dir, id, i));
    final pfpFile = File(_prevPfpPath(dir, id, i));
    final idKey = 'previousImage${i}Id_$id';
    final urlKey = 'previousImage${i}Url_$id';
    final pfpKey = 'previousImage${i}SenderPfpUrl_$id';
    final nameKey = 'previousImage${i}Sender_$id';

    // No image for this slot (fewer than 3 images available): clear it.
    if (i >= images.length) {
      if (await imgFile.exists()) await imgFile.delete();
      if (await pfpFile.exists()) await pfpFile.delete();
      await HomeWidget.saveWidgetData(urlKey, '');
      await HomeWidget.saveWidgetData(pfpKey, '');
      await HomeWidget.saveWidgetData(nameKey, '');
      await HomeWidget.saveWidgetData(idKey, '');
      continue;
    }

    final prev = images[i];
    final prevId = _photoKey(prev);
    final prevApi = _apiFor(prev);
    if (prevApi == null) continue;
    final storedId = await HomeWidget.getWidgetData<String>(idKey);

    if (storedId != prevId || !await imgFile.exists()) {
      final result = await prevApi.getImage(prev.id, lowRes: true);
      if (result.success && result.data != null) {
        await imgFile.writeAsBytes(result.data!, flush: true);
        await HomeWidget.saveWidgetData(urlKey, imgFile.path);
        await HomeWidget.saveWidgetData(idKey, prevId);
        changed = true;
        // The uploader may have changed, so refresh their name and pfp too.
        if (await _savePrevSender(prev, pfpFile, pfpKey, nameKey)) {
          changed = true;
        }
      }
    } else {
      // Image already correct. Repair the sender name if it was never stored,
      // and the pfp if its file went missing.
      final storedName = await HomeWidget.getWidgetData<String>(nameKey);
      final storedPfp = await HomeWidget.getWidgetData<String>(pfpKey);
      final pfpLost =
          (storedPfp?.isNotEmpty ?? false) && !await pfpFile.exists();
      if (storedName == null || pfpLost) {
        await _savePrevSender(prev, pfpFile, pfpKey, nameKey);
        changed = true;
      }
    }
  }

  return changed;
}

/// Fetch and store the uploader's name and pfp for a previous image.
/// Returns true if a pfp file was written.
Future<bool> _savePrevSender(
    ImageRef prev, File pfpFile, String pfpKey, String nameKey) async {
  final api = _apiFor(prev);
  if (api == null) return false;
  final prevId = prev.id;
  try {
    final details = await api.getImageDetails(prevId);
    final uploaderId = details.data?.uploadedBy;
    if (uploaderId == null) return false;
    final name =
        (await api.getUserDetails(uploaderId)).data?.username ?? "Unknown";
    await HomeWidget.saveWidgetData(nameKey, name);
    final result = await api.getProfilePictureBytes(uploaderId);
    if (result.success && result.data != null) {
      await pfpFile.writeAsBytes(result.data!, flush: true);
      await HomeWidget.saveWidgetData(pfpKey, pfpFile.path);
      return true;
    }
    if (await pfpFile.exists()) await pfpFile.delete();
    await HomeWidget.saveWidgetData(pfpKey, '');
  } catch (e) {
    debugPrint("Widget: prev sender save failed: $e");
  }
  return false;
}

/// Auto-save the newest received image to the gallery, at most once per image
/// id across all widgets, when the user has the setting enabled.
Future<void> _maybeAutoSave(
    String imageId, Uint8List bytes, String uploaderName) async {
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
