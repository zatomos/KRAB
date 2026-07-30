import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What one image notification on screen stands for.
///
/// A photo sent to several servers, or to several groups on one, arrives as one
/// push per sender and all of them land on the same notification id. Each has to
/// fold into what is already showing rather than replace it, so what is showing
/// has to be readable.
class ShownImageNotification {
  const ShownImageNotification({
    required this.groupsDisplay,
    required this.imageIds,
    required this.tapGroupId,
    required this.shownAt,
  });

  /// The group names the notification currently lists.
  final String groupsDisplay;

  /// Every copy of the photo it now speaks for, comma separated.
  final String imageIds;

  /// The group a tap opens, empty when it opens the cross-group feed.
  final String tapGroupId;

  final DateTime shownAt;

  Map<String, dynamic> toJson() => {
        'groups_display': groupsDisplay,
        'image_ids': imageIds,
        'tap_group_id': tapGroupId,
        'shown_at': shownAt.toIso8601String(),
      };

  static ShownImageNotification? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final shownAt = DateTime.tryParse(raw['shown_at']?.toString() ?? '');
    if (shownAt == null) return null;
    return ShownImageNotification(
      groupsDisplay: raw['groups_display']?.toString() ?? '',
      imageIds: raw['image_ids']?.toString() ?? '',
      tapGroupId: raw['tap_group_id']?.toString() ?? '',
      shownAt: shownAt,
    );
  }

  /// Whether this notification is speaking for the given copy of a photo.
  bool covers(String imageId) =>
      imageId.isNotEmpty &&
      imageIds.split(',').map((s) => s.trim()).contains(imageId);
}

/// The image notifications this device has posted, by notification id.
class ShownImageNotifications {
  ShownImageNotifications._();
  static final ShownImageNotifications instance = ShownImageNotifications._();

  static const String prefsKey = 'krab_shown_image_notifications';

  /// Entries older than this are dropped
  static const Duration maxAge = Duration(days: 2);

  /// Read-modify-write is not atomic across isolates, but two copies of one
  /// photo are handled by the same isolate, and this keeps them from interleaving
  /// between reading what is shown and recording what replaced it.
  Future<void> _tail = Future.value();

  Future<T> serialized<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ShownImageNotification?> read(int id) async {
    final entries = await _read();
    return entries['$id'];
  }

  /// Record what the notification now says, replacing any earlier record of it.
  Future<void> record(int id, ShownImageNotification entry) async {
    final entries = await _read();
    entries['$id'] = entry;
    await _write(entries);
  }

  Future<void> forget(Iterable<int> ids) async {
    if (ids.isEmpty) return;
    final entries = await _read();
    var changed = false;
    for (final id in ids) {
      if (entries.remove('$id') != null) changed = true;
    }
    if (changed) await _write(entries);
  }

  /// The ids of every notification standing for this copy of a photo, so a
  /// deleted photo can be taken off the screen even where it was merged into a
  /// notification another copy started.
  Future<List<int>> idsCovering(String imageId) async {
    if (imageId.isEmpty) return const [];
    final entries = await _read();
    return [
      for (final entry in entries.entries)
        if (entry.value.covers(imageId)) int.parse(entry.key)
    ];
  }

  Future<Map<String, ShownImageNotification>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    // Another isolate may have written since this one last looked.
    await prefs.reload();

    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return {};

    final entries = <String, ShownImageNotification>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final cutoff = DateTime.now().subtract(maxAge);
      for (final entry in decoded.entries) {
        final id = int.tryParse(entry.key.toString());
        final value = ShownImageNotification.fromJson(entry.value);
        if (id == null || value == null) continue;
        if (value.shownAt.isBefore(cutoff)) continue;
        entries['$id'] = value;
      }
    } catch (e) {
      debugPrint('notif: unreadable notification record: $e');
      return {};
    }
    return entries;
  }

  Future<void> _write(Map<String, ShownImageNotification> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode({
        for (final entry in entries.entries) entry.key: entry.value.toJson()
      }),
    );
  }
}
