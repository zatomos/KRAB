import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:krab/models/cached_url.dart';

class ProfilePictureCache {
  static const _prefsKey = 'pfp_cache';

  /// How long to wait after the last change before writing to disk, so a burst
  /// of avatar fetches coalesces into one write rather than re-encoding the
  /// whole map per URL.
  static const _persistDebounce = Duration(milliseconds: 400);

  /// Retire a cached URL before its signature actually expires.
  static const _expiryMargin = Duration(minutes: 5);

  static ProfilePictureCache? _instance;

  final SupabaseClient _supabase;
  final Map<String, CachedUrl> _memory = {};
  Timer? _persistTimer;

  ProfilePictureCache._(this._supabase);

  static ProfilePictureCache of(SupabaseClient supabase) {
    return _instance ??= ProfilePictureCache._(supabase);
  }

  /// Load persisted cache on app startup, dropping anything already stale.
  Future<void> hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final deadline = DateTime.now().subtract(_expiryMargin);
      for (final entry in map.entries) {
        final cached = CachedUrl.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (cached.expiry.isAfter(deadline)) _memory[entry.key] = cached;
      }
    } catch (_) {
      await prefs.remove(_prefsKey);
    }
  }

  /// Coalesce rapid changes into a single disk write.
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(_persistDebounce, _persist);
  }

  /// Persist cache, sweeping out entries that are dead beyond recovery.
  Future<void> _persist() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    final deadline = DateTime.now().subtract(_expiryMargin);
    _memory.removeWhere((_, cached) => cached.expiry.isBefore(deadline));

    final prefs = await SharedPreferences.getInstance();
    final map = _memory.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_prefsKey, jsonEncode(map));
  }

  /// Clear cache
  Future<void> clear() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    _memory.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  /// Get a signed URL
  Future<String?> getUrl(String id,
      {String bucket = 'profile-pictures',
      Duration ttl = const Duration(hours: 1)}) async {
    // Try memory
    final cached = _memory[id];
    if (cached != null && cached.isValid) {
      return cached.url;
    }

    // Fetch new signed URL
    try {
      final url = await _supabase.storage
          .from(bucket)
          .createSignedUrl(id, ttl.inSeconds);

      if (url.isEmpty) return null;

      // Expire the entry before the signature does, never after.
      final usableFor = ttl > _expiryMargin ? ttl - _expiryMargin : ttl ~/ 2;
      final fresh = CachedUrl(url, DateTime.now().add(usableFor));
      _memory[id] = fresh;
      _schedulePersist();
      return url;
    } catch (e) {
      return cached?.url; // last resort: stale
    }
  }

  /// Force refresh
  Future<String?> refresh(String id,
      {String bucket = 'profile-pictures',
      Duration ttl = const Duration(hours: 1)}) async {
    _memory.remove(id);
    return getUrl(id, bucket: bucket, ttl: ttl);
  }
}
