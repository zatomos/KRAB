import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which copies this device sent as one image.
///
/// It is a fallback, not a mechanism: it is consulted only when a copy comes
/// back with no share id of its own, and it only ever knows about this device's
/// own sends.
class ShareLedger {
  ShareLedger._();
  static final ShareLedger instance = ShareLedger._();

  static const String prefsKey = 'krab_share_ledger';

  /// How many mappings to keep.
  static const int maxEntries = 500;

  /// `instanceId/imageId` -> share id.
  Map<String, String> _entries = {};

  Future<void>? _loading;

  /// Serialises the read-modify-write in record
  Future<void> _writes = Future.value();

  static String _key(String instanceId, String imageId) =>
      '$instanceId/$imageId';

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      _entries = Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (e) {
      debugPrint('ShareLedger: unreadable, starting empty: $e');
      _entries = {};
    }
  }

  /// Record that a copy belongs to a share. Called once per instance an image
  /// was fanned out to.
  Future<void> record({
    required String instanceId,
    required String imageId,
    required String shareId,
  }) {
    return _writes = _writes.then((_) async {
      await _ensureLoaded();
      final key = _key(instanceId, imageId);
      _entries.remove(key);
      _entries[key] = shareId;

      // Oldest first
      while (_entries.length > maxEntries) {
        _entries.remove(_entries.keys.first);
      }

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsKey, jsonEncode(_entries));
      } catch (e) {
        debugPrint('ShareLedger: could not persist: $e');
      }
    }).catchError((Object e) {
      debugPrint('ShareLedger: record failed: $e');
    });
  }

  /// The share this copy belongs to, if this device is the one that sent it.
  Future<String?> shareIdFor(String instanceId, String imageId) async {
    await _ensureLoaded();
    return _entries[_key(instanceId, imageId)];
  }

  /// Synchronous lookup for code already past an await; null before the ledger
  /// has been read at least once.
  String? cachedShareIdFor(String instanceId, String imageId) =>
      _entries[_key(instanceId, imageId)];

  /// Read the ledger into memory so cachedShareIdFor can answer. Called at
  /// startup alongside the other stores.
  Future<void> load() => _ensureLoaded();

  @visibleForTesting
  void resetForTest() {
    _entries = {};
    _loading = null;
    _writes = Future.value();
  }
}
