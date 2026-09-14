import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/config.dart';
import 'package:krab/services/auth/app_auth.dart';
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

  final List<KrabInstance> _instances = [];

  final StreamController<InstanceAuthEvent> _authEvents =
      StreamController<InstanceAuthEvent>.broadcast();
  final Map<String, StreamSubscription<AppAuthStatus>> _authSubscriptions = {};

  /// Auth events from every instance, tagged with the one they came from.
  Stream<InstanceAuthEvent> get authEvents => _authEvents.stream;

  final StreamController<String> _removals =
      StreamController<String>.broadcast();

  final StreamController<void> _orderChanges =
      StreamController<void>.broadcast();

  /// Announced when the ranking changes.
  Stream<void> get orderChanged => _orderChanges.stream;

  /// Ids of instances that have been disconnected.
  ///
  /// Anything holding onto an instance listens here: push registration to forget
  /// its token, and any screen showing that instance's content to leave.
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

  /// The instance already connected to this URL, if there is one.
  KrabInstance? byUrl(String url) {
    final normalized = _normalizeUrl(url);
    return _instances.where((i) => i.url == normalized).firstOrNull;
  }

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
      final baked = _bakedInstance();
      if (baked != null) {
        _instances.add(baked);
        await _persist(prefs);
      }
    }

    for (final instance in _instances) {
      _attach(instance);
    }

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
      // The id carried over, so the stored session is still this instance's.
      // Load it, or the replacement would look signed out.
      await replacement.load();
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
  ///
  /// The move is applied to the in-memory list before the first suspension, so
  /// a caller may rebuild on the same frame it calls this and see the new order.
  /// A reorderable list needs that: its drop animation redraws immediately, and
  /// waiting for the returned future would animate the old order into place and
  /// then snap. The future completes once the new order is on disk.
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _instances.length) return;

    final target = newIndex.clamp(0, _instances.length - 1);
    if (target == oldIndex) return;

    final moved = _instances.removeAt(oldIndex);
    _instances.insert(target, moved);

    if (!_orderChanges.isClosed) _orderChanges.add(null);

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

  /// The instance a build can name for itself, for the first run of a build
  /// that ships pointed at one server. Null when this build names none, which
  /// leaves the connect screen to ask.
  KrabInstance? _bakedInstance() {
    final url = _clean(bakedSupabaseUrl);
    final anonKey = _clean(bakedSupabaseAnonKey);
    if (url.isEmpty || anonKey.isEmpty) return null;

    return KrabInstance(
      id: 'inst_1',
      url: _normalizeUrl(url),
      anonKey: anonKey,
    );
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
