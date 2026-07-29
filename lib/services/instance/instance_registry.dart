import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/config.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/instance/instance_config.dart';
import 'package:krab/services/instance/krab_instance.dart';

/// An auth event, and which instance it came from.
class InstanceAuthEvent {
  const InstanceAuthEvent(this.instance, this.status);
  final KrabInstance instance;
  final AppAuthStatus status;

  @override
  String toString() => 'InstanceAuthEvent{${instance.id}: ${status.name}}';
}

/// Every KRAB backend this install is connected to.
class InstanceRegistry {
  InstanceRegistry._();
  static final InstanceRegistry instance = InstanceRegistry._();
  static const String prefsKey = 'krab_instances';

  /// Highest instance id handed out so far.
  static const String counterPrefsKey = 'krab_instance_counter';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  final List<KrabInstance> _instances = [];

  final StreamController<InstanceAuthEvent> _authEvents =
      StreamController<InstanceAuthEvent>.broadcast();
  final Map<String, StreamSubscription<AppAuthStatus>> _authSubscriptions = {};

  /// Auth events from every instance, tagged with the one they came from.
  Stream<InstanceAuthEvent> get authEvents => _authEvents.stream;

  final StreamController<String> _removals = StreamController<String>.broadcast();

  /// Ids of instances that have been disconnected.
  ///
  /// Push registration listens: which instance owns the default FirebaseApp is
  /// decided by position in this list, so disconnecting one can hand that app to
  /// a different server, and every token has to be minted again.
  Stream<String> get removals => _removals.stream;

  List<KrabInstance> get all => List.unmodifiable(_instances);

  bool get isEmpty => _instances.isEmpty;

  /// The instances the user is signed into. The ones that can answer for
  /// anything.
  List<KrabInstance> get signedIn =>
      _instances.where((i) => i.auth.isLoggedIn).toList();

  bool get anySignedIn => _instances.any((i) => i.auth.isLoggedIn);

  /// The one instance, when there is exactly one.
  KrabInstance? get sole => _instances.length == 1 ? _instances.first : null;

  KrabInstance? byId(String? id) {
    if (id == null) return null;
    for (final instance in _instances) {
      if (instance.id == id) return instance;
    }
    return null;
  }

  /// Read the persisted instances
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    _detachAll();
    _instances.clear();

    final raw = prefs.getString(prefsKey);
    if (raw != null && raw.isNotEmpty) {
      _instances.addAll(_decode(raw));
    }

    if (_instances.isEmpty) {
      final migrated = await _migrateLegacyInstance(prefs);
      if (migrated != null) {
        _instances.add(migrated);
        await _persist(prefs);
      }
    }

    for (final instance in _instances) {
      _attach(instance);
    }

    // Remove leftover, TODO: remove later
    await prefs.remove('krab_active_instance');

    debugPrint('InstanceRegistry: ${_instances.length} instance(s)');
  }

  /// Load the sessions of every instance into memory.
  Future<void> loadSessions() async {
    for (final instance in _instances) {
      await instance.load();
    }
  }

  List<KrabInstance> _decode(String raw) {
    final decoded = <KrabInstance>[];
    try {
      final list = jsonDecode(raw) as List;
      for (final entry in list) {
        try {
          decoded.add(
              KrabInstance.fromJson(Map<String, dynamic>.from(entry as Map)));
        } catch (e) {
          debugPrint('InstanceRegistry: dropping unreadable instance: $e');
        }
      }
    } catch (e) {
      debugPrint('InstanceRegistry: unreadable instance list: $e');
    }
    return decoded;
  }

  Future<void> _persist(SharedPreferences prefs) async {
    await prefs.setString(
      prefsKey,
      jsonEncode(_instances.map((i) => i.toJson()).toList()),
    );
  }

  /// Write the list back after an instance's config changed.
  Future<void> persistConfig(KrabInstance instance) async {
    if (byId(instance.id) == null) return;
    final prefs = await SharedPreferences.getInstance();
    await _persist(prefs);
  }

  /// Connect this install to a backend.
  Future<KrabInstance> connect({
    required String url,
    required String anonKey,
    String displayName = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeUrl(url);

    final existing = _instances.where((i) => i.url == normalized).firstOrNull;
    if (existing != null && existing.anonKey == anonKey) return existing;

    // Same server, new key
    if (existing != null) {
      final replacement = KrabInstance(
        id: existing.id,
        url: normalized,
        anonKey: anonKey,
        displayName:
            displayName.isNotEmpty ? displayName : existing.displayName,
        config: existing.config,
      );
      _detach(existing);
      _instances[_instances.indexOf(existing)] = replacement;
      await existing.dispose();
      _attach(replacement);
      await _persist(prefs);
      return replacement;
    }

    final instance = KrabInstance(
      id: await _nextId(prefs),
      url: normalized,
      anonKey: anonKey,
      displayName: displayName,
    );
    _instances.add(instance);
    _attach(instance);
    await _persist(prefs);
    return instance;
  }

  /// Move an instance to a new position in the list.
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _instances.length) return;

    final target = newIndex.clamp(0, _instances.length - 1);
    if (target == oldIndex) return;

    final moved = _instances.removeAt(oldIndex);
    _instances.insert(target, moved);

    final prefs = await SharedPreferences.getInstance();
    await _persist(prefs);
  }

  /// Disconnect from an instance: forget its session, its caches and its entry.
  Future<void> remove(String id) async {
    final instance = byId(id);
    if (instance == null) return;

    await instance.auth.forgetSession();
    await instance.clearCaches();

    _detach(instance);
    _instances.remove(instance);
    await instance.dispose();

    final prefs = await SharedPreferences.getInstance();
    await _persist(prefs);

    // Announced after the list is settled, so a listener that re-reads it sees
    // the instance gone.
    if (!_removals.isClosed) _removals.add(id);
  }

  /// Ids look like `inst_3`, handed out from a counter that only ever goes up.
  Future<String> _nextId(SharedPreferences prefs) async {
    var next = prefs.getInt(counterPrefsKey) ?? 0;
    for (final instance in _instances) {
      final n = int.tryParse(instance.id.replaceFirst('inst_', ''));
      if (n != null && n >= next) next = n;
    }
    next += 1;
    await prefs.setInt(counterPrefsKey, next);
    return 'inst_$next';
  }

  static String _normalizeUrl(String url) {
    var trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  void _attach(KrabInstance instance) {
    _authSubscriptions[instance.id] = instance.auth.events.listen((status) {
      if (_authEvents.isClosed) return;
      _authEvents.add(InstanceAuthEvent(instance, status));
    });
  }

  void _detach(KrabInstance instance) {
    _authSubscriptions.remove(instance.id)?.cancel();
  }

  void _detachAll() {
    for (final subscription in _authSubscriptions.values) {
      subscription.cancel();
    }
    _authSubscriptions.clear();
  }

  // ---------------------------------------------------------------------------
  // Migration off the single-instance layout: TODO: remove later
  // ---------------------------------------------------------------------------

  /// Prefs keys the single-instance build used, cleared once migrated.
  static const List<String> _legacyKeys = [
    'supabaseUrl',
    'supabaseAnonKey',
    'fcmAppId',
    'fcmApiKey',
    'fcmSenderId',
    'fcmProjectId',
    'passwordResetUrl',
    'emailConfirmUrl',
  ];

  /// Build the first instance from whatever the single-instance build left
  /// behind.
  Future<KrabInstance?> _migrateLegacyInstance(SharedPreferences prefs) async {
    final url = _clean(prefs.getString('supabaseUrl') ?? bakedSupabaseUrl);
    final anonKey =
        _clean(prefs.getString('supabaseAnonKey') ?? bakedSupabaseAnonKey);
    if (url.isEmpty || anonKey.isEmpty) return null;

    final instance = KrabInstance(
      id: 'inst_1',
      url: _normalizeUrl(url),
      anonKey: anonKey,
      config: InstanceConfig(
        fcmAppId: prefs.getString('fcmAppId') ?? '',
        fcmApiKey: prefs.getString('fcmApiKey') ?? '',
        fcmSenderId: prefs.getString('fcmSenderId') ?? '',
        fcmProjectId: prefs.getString('fcmProjectId') ?? '',
        passwordResetUrl: prefs.getString('passwordResetUrl') ?? '',
        emailConfirmUrl: prefs.getString('emailConfirmUrl') ?? '',
      ),
    );

    await _migrateLegacySession(prefs, instance);
    await _migrateGroupLists(prefs, instance.id);

    for (final key in _legacyKeys) {
      await prefs.remove(key);
    }

    debugPrint('InstanceRegistry: migrated ${instance.url} to ${instance.id}');
    return instance;
  }

  Future<void> _migrateGroupLists(
      SharedPreferences prefs, String instanceId) async {
    for (final key in ['favoriteGroups', 'mutedGroups']) {
      final existing = prefs.getStringList(key);
      if (existing == null || existing.isEmpty) continue;
      await prefs.setStringList(
        key,
        existing
            .map((id) => id.contains('/') ? id : '$instanceId/$id')
            .toList(),
      );
    }
  }

  Future<void> _migrateLegacySession(
      SharedPreferences prefs, KrabInstance instance) async {
    final target = sessionStorageKey(instance.id);
    try {
      if (await _storage.read(key: target) != null) return;

      var session = await _storage.read(key: legacySessionStorageKey);

      if (session == null || session.isEmpty) {
        final host = Uri.tryParse(instance.url)?.host ?? '';
        if (host.isNotEmpty) {
          session = prefs.getString('sb-${host.split('.').first}-auth-token');
        }
      }

      if (session == null || session.isEmpty) return;

      await _storage.write(key: target, value: session);
      await _storage.delete(key: legacySessionStorageKey);
      debugPrint('InstanceRegistry: moved the stored session to $target');
    } catch (e) {
      debugPrint('InstanceRegistry: session migration failed: $e');
    }
  }

  /// Trims a config value and strips a matching pair of surrounding quotes.
  static String _clean(String? raw) {
    var v = (raw ?? '').trim();
    if (v.length >= 2 &&
        ((v.startsWith("'") && v.endsWith("'")) ||
            (v.startsWith('"') && v.endsWith('"')))) {
      v = v.substring(1, v.length - 1).trim();
    }
    return v;
  }
}
