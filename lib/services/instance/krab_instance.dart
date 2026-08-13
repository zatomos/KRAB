import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/cache/image_disk_cache.dart';
import 'package:krab/services/cache/profile_picture_cache.dart';
import 'package:krab/services/cache/reaction_cache.dart';
import 'package:krab/services/cache/viewer_cache.dart';
import 'package:krab/services/instance/instance_config.dart';
import 'package:krab/services/instance/instance_registry.dart';

/// One KRAB backend this install is connected to, and everything held against
/// it: the session, the Supabase client, the caches and the API.
///
/// Nothing here is static. Two instances share no session, no signed URLs and
/// no cached photos, so one server being slow, unreachable or signed out cannot
/// affect another.
///
/// The client is built directly rather than through `Supabase.initialize`,
/// which is a singleton. That is only possible because the session lives in
/// [AppAuth] and reaches the client through the `accessToken` hook, so the
/// client itself is stateless with respect to auth.
class KrabInstance {
  KrabInstance({
    required this.id,
    required this.url,
    required this.anonKey,
    this.displayName = '',
    InstanceConfig config = InstanceConfig.empty,
  }) : _config = config;

  /// Stable identifier for this instance on this device. Names the session's
  /// storage key, the auth lock file and the image cache directory, so it must
  /// stay safe in all three and must never be reused for a different backend.
  final String id;

  final String url;
  final String anonKey;

  /// What to call this instance in the UI. Falls back to its host.
  final String displayName;

  InstanceConfig _config;

  /// This instance's published settings, as last fetched.
  InstanceConfig get config => _config;

  /// A name for the UI: the operator's if it set one, otherwise the host.
  String get label =>
      displayName.isNotEmpty ? displayName : (Uri.tryParse(url)?.host ?? url);

  late final AppAuth auth = AppAuth(instanceId: id, url: url, anonKey: anonKey);

  late final SupabaseClient client = SupabaseClient(
    url,
    anonKey,
    // Third-party-auth mode: the client holds no session; every request asks
    // this instance's AppAuth for a valid token.
    accessToken: auth.getValidToken,
  );

  late final ProfilePictureCache pictures =
      ProfilePictureCache(client: client, instanceId: id);

  late final ImageDiskCache imageCache = ImageDiskCache(instanceId: id);

  late final KrabApi api = KrabApi(this);

  final ReactionCache reactions = ReactionCache();

  late final ViewerCache viewer = ViewerCache(api);

  /// Load this instance's persisted session into memory. Call once per isolate
  /// before making any request.
  Future<void> load() => auth.load();

  /// Record freshly fetched settings and persist them alongside the instance.
  Future<void> updateConfig(InstanceConfig config) async {
    _config = config;
    await InstanceRegistry.instance.persistConfig(this);
  }

  /// Drop everything cached for this instance, leaving other instances alone.
  Future<void> clearCaches() async {
    await pictures.clear();
    await imageCache.clear();
    reactions.clear();
    viewer.clear();
  }

  /// Release the client and the auth event stream. Called when an instance is
  /// removed, never during normal use.
  Future<void> dispose() async {
    try {
      await client.dispose();
    } catch (e) {
      debugPrint('KrabInstance[$id]: client dispose failed: $e');
    }
    await auth.dispose();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'anon_key': anonKey,
        'display_name': displayName,
        'config': _config.toJson(),
      };

  /// Reads back what [toJson] wrote. Throws on a malformed entry, which the
  /// registry treats as a dropped instance rather than a crash.
  factory KrabInstance.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final url = json['url'] as String;
    final anonKey = json['anon_key'] as String;
    if (id.isEmpty || url.isEmpty || anonKey.isEmpty) {
      throw const FormatException('instance entry missing id/url/anon_key');
    }
    final config = json['config'];
    return KrabInstance(
      id: id,
      url: url,
      anonKey: anonKey,
      displayName: json['display_name'] as String? ?? '',
      config: config is Map
          ? InstanceConfig.fromJson(Map<String, dynamic>.from(config))
          : InstanceConfig.empty,
    );
  }

  @override
  String toString() => 'KrabInstance{id: $id, url: $url}';
}
