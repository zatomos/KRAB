import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../user_preferences.dart';

const FlutterSecureStorage _bgStorage = FlutterSecureStorage();

// One independent background session per background isolate, each under its own
// Keystore key. Because two independent Supabase sessions never share a refresh
// token, no two isolates can ever invalidate each other's token
const String _fcmSessionKey = 'krab_bg_fcm_session';
const String _workmanagerSessionKey = 'krab_bg_workmanager_session';

/// Secure-storage-backed LocalStorage for one background Supabase session.
///
/// Each background isolate gets its own session, completely separate from the
/// interactive UI session and from the other background isolate's session.
class SecureBackgroundLocalStorage extends LocalStorage {
  const SecureBackgroundLocalStorage(this.sessionKey);

  /// Keystore key this session is stored under.
  final String sessionKey;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() => _bgStorage.containsKey(key: sessionKey);

  @override
  Future<String?> accessToken() => _bgStorage.read(key: sessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _bgStorage.write(key: sessionKey, value: persistSessionString);

  @override
  Future<void> removePersistedSession() =>
      _bgStorage.delete(key: sessionKey);
}

/// Manages the lifecycle of the per-isolate background session credentials.
class BackgroundSession {
  /// Storage for the FCM background handler's session.
  static const SecureBackgroundLocalStorage fcmStorage =
      SecureBackgroundLocalStorage(_fcmSessionKey);

  /// Storage for the WorkManager widget-refresh isolate's session.
  static const SecureBackgroundLocalStorage workmanagerStorage =
      SecureBackgroundLocalStorage(_workmanagerSessionKey);

  static const List<SecureBackgroundLocalStorage> _all = [
    fcmStorage,
    workmanagerStorage,
  ];

  /// True only when every background session is present. If any is missing the
  /// re-auth prompt mints them all again.
  static Future<bool> hasSession() async {
    for (final storage in _all) {
      if (!await storage.hasAccessToken()) return false;
    }
    return true;
  }

  /// Returns true if this isolate's background session was recovered and is
  /// usable. If it couldn't be, drops this isolate's own stored credential so
  /// hasSession reports false and the next app open re-mints via the prompt.
  /// Call right after initializing the isolate's Supabase client.
  static Future<bool> recoverOrClear(SecureBackgroundLocalStorage storage) async {
    if (Supabase.instance.client.auth.currentSession != null) return true;
    debugPrint('BG session: unrecoverable (${storage.sessionKey}); clearing own');
    await storage.removePersistedSession();
    return false;
  }

  /// Mints one independent Supabase session per background isolate and stores
  /// each in secure storage. Returns true only if all succeeded.
  static Future<bool> mintAndStore(String email, String password) async {
    final results = await Future.wait(
      _all.map((storage) => _mintInto(storage, email, password)),
    );
    return results.every((ok) => ok);
  }

  static Future<bool> _mintInto(
      SecureBackgroundLocalStorage storage, String email, String password) async {
    try {
      final url = UserPreferences.supabaseUrl;
      final anon = UserPreferences.supabaseAnonKey;
      if (url.isEmpty || anon.isEmpty) {
        debugPrint('BG session: Supabase config missing; skipping mint.');
        return false;
      }

      final data = await _postToken(Dio(), url, anon,
          query: {'grant_type': 'password'},
          body: {'email': email, 'password': password});

      final session = data == null ? null : Session.fromJson(data);
      if (session == null) {
        debugPrint('BG session: mint returned no session (${storage.sessionKey}).');
        return false;
      }

      // Persist in the exact format supabase_flutter reads back via
      // recoverSession
      await storage.persistSession(jsonEncode(session.toJson()));
      debugPrint('BG session: minted and stored (${storage.sessionKey}).');
      return true;
    } catch (e) {
      debugPrint('BG session: mint failed (${storage.sessionKey}): $e');
      return false;
    }
  }

  /// POST to the GoTrue token endpoint with the standard headers. Returns the
  /// decoded JSON body, or null if it wasn't a JSON object.
  static Future<Map<String, dynamic>?> _postToken(
    Dio dio,
    String url,
    String anon, {
    required Map<String, dynamic> query,
    required Map<String, dynamic> body,
  }) async {
    final response = await dio.post(
      '$url/auth/v1/token',
      queryParameters: query,
      data: body,
      options: Options(
        headers: {'apikey': anon, 'Content-Type': 'application/json'},
      ),
    );
    final data = response.data;
    return data is Map<String, dynamic> ? data : null;
  }

  /// Revokes every background session server-side and removes the
  /// local copies. Called on logout and password change.
  static Future<void> clear() async {
    await Future.wait(_all.map(_revokeAndRemove));
    debugPrint('BG session: cleared.');
  }

  static Future<void> _revokeAndRemove(
      SecureBackgroundLocalStorage storage) async {
    await _revokeServerSide(storage); // best-effort; never throws
    try {
      await storage.removePersistedSession();
    } catch (e) {
      debugPrint('BG session: local remove failed (${storage.sessionKey}): $e');
    }
  }

  /// Best-effort logout for one stored session, authenticated with that
  /// session's own token. Short timeouts and a blanket catch so it can never
  /// hang or break logout when offline.
  static Future<void> _revokeServerSide(
      SecureBackgroundLocalStorage storage) async {
    try {
      final url = UserPreferences.supabaseUrl;
      final anon = UserPreferences.supabaseAnonKey;
      if (url.isEmpty || anon.isEmpty) return;

      final raw = await storage.accessToken();
      if (raw == null) return;
      final session = Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (session == null) return;

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 4),
      ));

      // GoTrue rejects /logout with an expired token, so refresh first if needed
      var token = session.accessToken;
      if (session.isExpired && session.refreshToken != null) {
        try {
          final data = await _postToken(dio, url, anon,
              query: {'grant_type': 'refresh_token'},
              body: {'refresh_token': session.refreshToken!});
          if (data?['access_token'] is String) {
            token = data!['access_token'] as String;
          }
        } catch (_) {
          // Couldn't refresh, likely already revoked; fall through and try
          // logging out with the stale token, the server just ignores it.
        }
      }

      await dio.post(
        '$url/auth/v1/logout',
        queryParameters: {'scope': 'local'},
        options: Options(
            headers: {'apikey': anon, 'Authorization': 'Bearer $token'}),
      );
      debugPrint('BG session: revoked server-side (${storage.sessionKey}).');
    } catch (e) {
      debugPrint(
          'BG session: server-side revoke skipped (${storage.sessionKey}): $e');
    }
  }
}
