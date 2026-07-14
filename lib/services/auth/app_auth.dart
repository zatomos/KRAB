import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/services/auth/gotrue_api.dart';
import 'package:krab/services/auth/jwt.dart';
import 'package:krab/user_preferences.dart';

enum AppAuthStatus { signedIn, signedOut, tokenRefreshed }

/// Derive a session's absolute expiry from a GoTrue session JSON.
///
/// Preference order:
///  1. explicit `expires_at` (already absolute)
///  2. `expires_in` seconds, added to nowEpochSeconds
///  3. the access token's `exp` claim (from [claims])
///
/// Returns null when none are present or well-formed, which callers treat as
/// "unknown expiry" -> always refresh.
int? deriveExpiresAt(
  Map<String, dynamic> session,
  Map<String, dynamic>? claims,
  int nowEpochSeconds,
) {
  final expiresAt = session['expires_at'];
  if (expiresAt is int) return expiresAt;

  final expiresIn = session['expires_in'];
  if (expiresIn is int) return nowEpochSeconds + expiresIn;

  final exp = claims?['exp'];
  return exp is int ? exp : null;
}

/// Whether a token expiring at expiresAt should be refreshed now.
///
/// A null expiry always counts as near-expiry. Otherwise it's near-expiry
/// once we are within marginSeconds of the expiry instant,
/// including already past it.
bool isNearExpiry(int? expiresAt, int nowEpochSeconds, int marginSeconds) {
  if (expiresAt == null) return true;
  return expiresAt - nowEpochSeconds <= marginSeconds;
}

/// GoTrue error codes that prove the session is dead, so we need to
/// sign the user out.
/// Everything else is a failure of one attempt, not proof that
/// the session is gone.
const Set<String> fatalRefreshCodes = {
  'refresh_token_not_found',
  'refresh_token_revoked',
  'session_not_found',
  'session_expired',
  'user_not_found',
  'user_banned',
};

/// Whether a refresh rejection carrying code means the session is dead.
bool isFatalRefreshCode(String code) => fatalRefreshCodes.contains(code);

/// Result of an auth action. error is a GoTrue error code when success is false
class AuthResult {
  const AuthResult(this.success, [this.error]);
  final bool success;
  final String? error;
}

/// The single source of truth for the user's session, shared by every isolate.
///
/// KRAB uses supabase_flutter's accessToken hook: the Supabase clients hold
/// no session of their own; they call [getValidToken] for every request.
/// So there is exactly one refresh chain, owned here, and none of
/// supabase_flutter's session lifecycle is in play.
/// Refresh is single-flight across isolates via a file lock, and only
/// the GoTrue REST API is touched.
class AppAuth {
  AppAuth._();
  static final AppAuth instance = AppAuth._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _sessionKey = 'krab_session';

  /// Refresh this many seconds before the access token expires.
  static const int _refreshMarginSeconds = 300;

  final StreamController<AppAuthStatus> _events =
      StreamController<AppAuthStatus>.broadcast();

  // In-memory view of the current session.
  String? _accessToken;
  String? _refreshToken;
  int? _expiresAt; // epoch seconds
  Map<String, dynamic>? _claims;

  // Serialization of refreshes; the file lock serializes across.
  Future<void> _chain = Future<void>.value();

  // A refresh token the server has rejected, and how many times running.
  String? _rejectedToken;
  int _rejectionCount = 0;

  /// How many consecutive rejections of the same refresh token it takes before
  /// the session is treated as genuinely dead.
  static const int _maxRejections = 3;

  GotrueApi get _api =>
      GotrueApi(UserPreferences.supabaseUrl, UserPreferences.supabaseAnonKey);

  /// Emits when the user signs in/out or the token is refreshed.
  Stream<AppAuthStatus> get events => _events.stream;

  bool get isLoggedIn => _refreshToken != null;
  String? get currentUserId => _claims?['sub'] as String?;
  String? get currentUserEmail => _claims?['email'] as String?;

  /// Load the persisted session into memory. Call once per isolate at startup,
  /// before initializing Supabase. Only reads storage.
  Future<void> load() async {
    try {
      var raw = await _storage.read(key: _sessionKey);
      raw ??= await _migrateLegacySession();
      if (raw != null && raw.isNotEmpty) {
        await _apply(jsonDecode(raw) as Map<String, dynamic>, persist: false);
      }
    } catch (e) {
      debugPrint('AppAuth.load failed: $e');
    }
  }

  /// One-time migration for users logged in on the previous build.
  Future<String?> _migrateLegacySession() async {
    try {
      final url = UserPreferences.supabaseUrl;
      if (url.isEmpty) return null;
      final host = Uri.parse(url).host;
      if (host.isEmpty) return null;
      final legacyKey = 'sb-${host.split('.').first}-auth-token';
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(legacyKey);
      if (legacy == null || legacy.isEmpty) return null;
      await _storage.write(key: _sessionKey, value: legacy);
      debugPrint('AppAuth: migrated legacy session from SharedPreferences.');
      return legacy;
    } catch (e) {
      debugPrint('AppAuth: legacy migration failed: $e');
      return null;
    }
  }

  /// The `accessToken` callback wired into every Supabase client. Returns a
  /// valid JWT, refreshing if near expiry, or null when logged out.
  Future<String?> getValidToken() async {
    if (_refreshToken == null) return null;
    if (_accessToken != null && !_isNearExpiry()) return _accessToken;
    await _ensureFresh();
    return _accessToken;
  }

  bool _isNearExpiry() => isNearExpiry(
        _expiresAt,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        _refreshMarginSeconds,
      );

  // ---------------------------------------------------------------------------
  // Auth actions (GoTrue REST)
  // ---------------------------------------------------------------------------

  Future<AuthResult> login(String email, String password) =>
      _runAction(() async {
        await _apply(await _api.passwordGrant(email, password), persist: true);
        _events.add(AppAuthStatus.signedIn);
      });

  /// Register a new account. The username is stored in signup metadata so the
  /// profile can be created server-side even before email confirmation.
  ///
  /// If email confirmation is disabled the signup response includes a session
  /// and we sign in immediately; otherwise no session is returned and the caller
  /// must have the user confirm their email before logging in.
  Future<AuthResult> register(String email, String password,
          {String? username, String? redirectTo}) =>
      _runAction(() async {
        final res = await _api.signUp(email, password,
            data: username == null ? null : {'username': username},
            redirectTo: redirectTo);

        // Email confirmation disabled: signup returns a session, sign in now.
        if (res['access_token'] != null && res['refresh_token'] != null) {
          await _apply(res, persist: true);
          _events.add(AppAuthStatus.signedIn);
          return;
        }

        // No session in the signup response. Either confirmation is required, or
        // this server auto-confirms but doesn't return a session on signup. Try
        // to log in: success means we're auto-confirmed; email_not_confirmed
        // means the user must verify first.
        try {
          await _apply(await _api.passwordGrant(email, password),
              persist: true);
          _events.add(AppAuthStatus.signedIn);
        } on GotrueAuthException catch (e) {
          if (e.code != 'email_not_confirmed') rethrow;
        }
      });

  /// Re-send the signup confirmation email for an unconfirmed account.
  Future<AuthResult> resendConfirmation(String email, {String? redirectTo}) =>
      _runAction(() => _api.resendSignup(email, redirectTo: redirectTo));

  Future<AuthResult> changePassword(
          String currentPassword, String newPassword) =>
      _runAction(() async {
        final email = currentUserEmail;
        if (email == null) throw const GotrueAuthException('no_current_user');
        // Verify the current password and obtain a fresh token to authorize the
        // change, then re-grant on the new password so the stored session stays
        // valid.
        await _apply(await _api.passwordGrant(email, currentPassword),
            persist: true);
        await _api.updatePassword(_accessToken!, newPassword);
        await _apply(await _api.passwordGrant(email, newPassword),
            persist: true);
        _events.add(AppAuthStatus.tokenRefreshed);
      });

  Future<AuthResult> sendPasswordReset(String email, {String? redirectTo}) =>
      _runAction(() => _api.recover(email, redirectTo: redirectTo));

  /// Sign out: revoke server-side (best-effort) and clear local state.
  Future<void> logout() async {
    final token = _accessToken;
    if (token != null) await _api.logout(token);
    await _clear();
  }

  /// Drop the stored session without telling the server, and without announcing
  /// a sign-out.
  Future<void> forgetSession() async {
    _accessToken = _refreshToken = null;
    _expiresAt = null;
    _claims = null;
    _rejectedToken = null;
    _rejectionCount = 0;
    try {
      await _storage.delete(key: _sessionKey);
    } catch (e) {
      debugPrint('AppAuth.forgetSession failed: $e');
    }
  }

  Future<AuthResult> _runAction(Future<void> Function() action) async {
    try {
      await action();
      return const AuthResult(true);
    } on GotrueAuthException catch (e) {
      return AuthResult(false, e.code);
    } on GotrueNetworkException {
      return const AuthResult(false, 'network_error');
    } catch (e) {
      return AuthResult(false, e.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Refresh (single-flight, cross-isolate)
  // ---------------------------------------------------------------------------

  Future<void> _ensureFresh() {
    final next = _chain.then((_) => _refreshLocked());
    _chain = next.catchError((_) {});
    return next;
  }

  Future<void> _refreshLocked() async {
    RandomAccessFile? lock;
    try {
      lock = await _acquireLock();

      if (lock == null) {
        await _reloadFromStore();
        return;
      }

      // Another isolate may have refreshed while we waited for the lock; adopt
      // whatever is now persisted before deciding to refresh.
      await _reloadFromStore();
      if (_refreshToken == null || !_isNearExpiry()) return;

      final used = _refreshToken!;
      try {
        await _apply(await _api.refreshGrant(used), persist: true);
        _rejectedToken = null;
        _rejectionCount = 0;
        _events.add(AppAuthStatus.tokenRefreshed);
      } on GotrueNetworkException {
        // Transient; keep the session and try again next time.
        debugPrint('AppAuth: refresh skipped (offline)');
      } on GotrueAuthException catch (e) {
        await _handleRefreshRejection(e, used);
      }
    } catch (e) {
      debugPrint('AppAuth._refreshLocked failed: $e');
    } finally {
      if (lock != null) {
        try {
          await lock.unlock();
          await lock.close();
        } catch (_) {}
      }
    }
  }

  /// Decide what a rejected refresh actually means before throwing the session
  /// away.
  Future<void> _handleRefreshRejection(
      GotrueAuthException e, String used) async {
    await _reloadFromStore();
    if (_refreshToken != null && _refreshToken != used) {
      debugPrint('AppAuth: refresh raced (${e.code}); '
          'adopted the session another isolate stored');
      _rejectedToken = null;
      _rejectionCount = 0;
      return;
    }

    if (isFatalRefreshCode(e.code)) {
      debugPrint('AppAuth: refresh rejected (${e.code}); signing out');
      await _clear();
      return;
    }

    _rejectionCount = (_rejectedToken == used) ? _rejectionCount + 1 : 1;
    _rejectedToken = used;

    if (_rejectionCount >= _maxRejections) {
      debugPrint('AppAuth: refresh rejected (${e.code}) '
          '$_rejectionCount times running; signing out');
      await _clear();
      return;
    }

    debugPrint('AppAuth: refresh failed (${e.code}, attempt $_rejectionCount); '
        'keeping the session and retrying later');
  }

  Future<void> _reloadFromStore() async {
    try {
      final raw = await _storage.read(key: _sessionKey);
      if (raw == null || raw.isEmpty) {
        _accessToken = _refreshToken = null;
        _expiresAt = null;
        _claims = null;
        return;
      }
      await _apply(jsonDecode(raw) as Map<String, dynamic>, persist: false);
    } catch (_) {}
  }

  /// Apply a GoTrue session JSON to memory and optionally persist it.
  ///
  /// When persist is true, the Keystore write is AWAITED, so a login or
  /// refresh cannot be lost if the process dies immediately afterwards.
  Future<void> _apply(Map<String, dynamic> session,
      {required bool persist}) async {
    final access = session['access_token'] as String?;
    final refresh = session['refresh_token'] as String?;
    if (access == null || refresh == null) {
      throw const GotrueAuthException('no_session_in_response');
    }
    _accessToken = access;
    _refreshToken = refresh;
    _claims = decodeJwtPayload(access);
    _expiresAt = deriveExpiresAt(
      session,
      _claims,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    if (persist) {
      // Persist the exact GoTrue session shape so any isolate can reload it.
      await _storage.write(key: _sessionKey, value: jsonEncode(session));
    }
  }

  Future<void> _clear() async {
    _accessToken = _refreshToken = null;
    _expiresAt = null;
    _claims = null;
    _rejectedToken = null;
    _rejectionCount = 0;
    try {
      await _storage.delete(key: _sessionKey);
    } catch (_) {}
    _events.add(AppAuthStatus.signedOut);
  }

  /// Best-effort cross-process exclusive lock. Returns null when the lock can't
  /// be taken, and the caller then adopts the persisted session rather than
  /// refreshing unlocked: rotation means a parallel refresh gets one of the two
  /// callers a spent-token rejection.
  Future<RandomAccessFile?> _acquireLock() async {
    try {
      final file = File('${Directory.systemTemp.path}/krab_auth.lock');
      final raf = await file.open(mode: FileMode.write);
      try {
        await raf.lock(FileLock.exclusive).timeout(const Duration(seconds: 8));
        return raf;
      } catch (e) {
        await raf.close();
        debugPrint('AppAuth: proceeding without lock: $e');
        return null;
      }
    } catch (e) {
      debugPrint('AppAuth: lock unavailable: $e');
      return null;
    }
  }
}
