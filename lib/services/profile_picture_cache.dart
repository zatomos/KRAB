import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:krab/models/cached_url.dart';

class ProfilePictureCache {
  static const _prefsKey = 'pfp_cache';
  // How long to wait after the last change before writing to disk, so a burst
  // of avatar fetches coalesces into one write instead of re-encoding and
  //persisting the whole map per URL.
  static const _persistDebounce = Duration(milliseconds: 400);
  static ProfilePictureCache? _instance;

  final SupabaseClient _supabase;
  final Map<String, CachedUrl> _memory = {};
  Timer? _persistTimer;

  ProfilePictureCache._(this._supabase);

  static ProfilePictureCache of(SupabaseClient supabase) {
    return _instance ??= ProfilePictureCache._(supabase);
  }

  /// Load persisted cache on app startup.
  Future<void> hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        _memory[entry.key] = CachedUrl.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
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

  /// Persist cache
  Future<void> _persist() async {
    _persistTimer?.cancel();
    _persistTimer = null;
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

      final fresh = CachedUrl(url, DateTime.now().add(ttl));
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
