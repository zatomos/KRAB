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
///
/// The list is the app's single source of truth for "which servers are we
/// talking to". It is persisted as a JSON array under [prefsKey] so the native
/// side can read it too: `KrabApplication` needs the FCM config before any
/// Dart runs, to bring Firebase up for a push that arrives while the app is
/// dead.
///
/// Phase 1 carries exactly one instance, but nothing here assumes that: the
/// shape, the persistence and the auth-event stream are all list-based, so
/// turning on more is a UI change rather than a rewrite.
class InstanceRegistry {
  InstanceRegistry._();
  static final InstanceRegistry instance = InstanceRegistry._();

  /// JSON array of instances. Also read natively — see the class doc.
  static const String prefsKey = 'krab_instances';

  /// Id of the instance the UI is currently showing.
  static const String activePrefsKey = 'krab_active_instance';

  /// Highest instance id handed out so far. See [_nextId].
  static const String counterPrefsKey = 'krab_instance_counter';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  final List<KrabInstance> _instances = [];
  String? _activeId;

  final StreamController<InstanceAuthEvent> _authEvents =
      StreamController<InstanceAuthEvent>.broadcast();
  final Map<String, StreamSubscription<AppAuthStatus>> _authSubscriptions = {};

  /// Auth events from every instance, tagged with the one they came from.
  ///
  /// Callers listen here rather than to a single session, so a sign-out on one
  /// server is reported as exactly that instead of as an app-wide sign-out.
  Stream<InstanceAuthEvent> get authEvents => _authEvents.stream;

  List<KrabInstance> get all => List.unmodifiable(_instances);

  bool get isEmpty => _instances.isEmpty;

  /// The instance the UI is currently working against, or null when this
  /// install is not connected to any backend yet.
  KrabInstance? get active {
    if (_instances.isEmpty) return null;
    return byId(_activeId) ?? _instances.first;
  }

  /// The active instance, for the many call sites that only run once there is
  /// one. Throws if called before a backend is configured.
  KrabInstance get requireActive {
    final current = active;
    if (current == null) {
      throw StateError('No KRAB instance is configured');
    }
    return current;
  }

  KrabInstance? byId(String? id) {
    if (id == null) return null;
    for (final instance in _instances) {
      if (instance.id == id) return instance;
    }
    return null;
  }

  /// Read the persisted instances, migrating a pre-multi-instance install on
  /// the way. Call once per isolate, at startup, before anything else here.
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

    _activeId = prefs.getString(activePrefsKey);
    if (byId(_activeId) == null) {
      _activeId = _instances.isEmpty ? null : _instances.first.id;
    }

    for (final instance in _instances) {
      _attach(instance);
    }

    debugPrint('InstanceRegistry: ${_instances.length} instance(s), '
        'active=$_activeId');
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
          // One unreadable entry must not take the others with it.
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

  /// Connect this install to a backend, and make it the active one.
  ///
  /// An existing instance for the same URL is reused rather than duplicated, so
  /// re-entering a server the user is already connected to keeps their session.
  Future<KrabInstance> connect({
    required String url,
    required String anonKey,
    String displayName = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeUrl(url);

    final existing = _instances.where((i) => i.url == normalized).firstOrNull;
    if (existing != null && existing.anonKey == anonKey) {
      await activate(existing.id);
      return existing;
    }

    // Same server, new key: replace it, keeping the id so the session and the
    // cached photos survive a rotated anon key.
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
      await activate(replacement.id);
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
    await activate(instance.id);
    return instance;
  }

  /// Make an instance the one the UI works against.
  Future<void> activate(String id) async {
    if (byId(id) == null) return;
    _activeId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(activePrefsKey, id);
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

    if (_activeId == id) {
      _activeId = _instances.isEmpty ? null : _instances.first.id;
      if (_activeId == null) {
        await prefs.remove(activePrefsKey);
      } else {
        await prefs.setString(activePrefsKey, _activeId!);
      }
    }
  }

  /// Ids look like `inst_3`, handed out from a counter that only ever goes up.
  ///
  /// It has to be persisted rather than derived from the instances in hand: an
  /// id names a session key, a lock file and a cache directory, so reusing one
  /// after a removal would hand a new backend the leftovers of an old one.
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

  /// Trailing slashes make two spellings of the same server look different.
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
  // Migration off the single-instance layout
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
  /// behind, or from this build's baked-in backend. Null when neither exists,
  /// which is a fresh install that must go through the connect screen.
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

  /// The favourite and muted lists held bare group ids; scope them to the
  /// instance those groups actually live on, so the user's choices survive.
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

  /// Move the session the single-instance build stored onto this instance's
  /// key, so migrating does not sign the user out.
  Future<void> _migrateLegacySession(
      SharedPreferences prefs, KrabInstance instance) async {
    final target = sessionStorageKey(instance.id);
    try {
      if (await _storage.read(key: target) != null) return;

      var session = await _storage.read(key: legacySessionStorageKey);

      // Older still: supabase_flutter's own SharedPreferences entry.
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
      // A failure here costs one sign-in, not the migration.
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
