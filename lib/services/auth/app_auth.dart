import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:krab/services/auth/gotrue_api.dart';
import 'package:krab/services/auth/jwt.dart';

enum AppAuthStatus { signedIn, signedOut, tokenRefreshed }

/// A session's absolute expiry, preferring `expires_at`, then `expires_in`,
/// then the access token's `exp` claim. Null when none are usable, which
/// callers treat as "unknown expiry" and always refresh.
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

/// Whether a token expiring at expiresAt should be refreshed now. An unknown
/// expiry always counts as near.
bool isNearExpiry(int? expiresAt, int nowEpochSeconds, int marginSeconds) {
  if (expiresAt == null) return true;
  return expiresAt - nowEpochSeconds <= marginSeconds;
}

/// GoTrue error codes that prove the session is dead. Everything else is one
/// attempt failing, not proof the session is gone.
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

/// The secure-storage key holding one instance's session.
String sessionStorageKey(String instanceId) => 'krab_session_$instanceId';

/// The secure-storage key sessions lived under before KRAB knew about more than
/// one instance. The registry moves it onto the migrated instance's key once.
const String legacySessionStorageKey = 'krab_session';

/// Result of an auth action. error is a GoTrue error code when success is false
class AuthResult {
  const AuthResult(this.success, [this.error]);
  final bool success;
  final String? error;
}

/// The source of truth for the user's session **on one instance**, shared by
/// every isolate.
///
/// The Supabase client for that instance holds no session of its own: it calls
/// [getValidToken] for every request through supabase's `accessToken` hook. So
/// there is exactly one refresh chain per instance, owned here, single-flighted
/// across isolates with a per-instance file lock and speaking only to that
/// instance's GoTrue REST API.
///
/// Instances are independent: a refresh against one server never blocks or
/// signs out another, because the lock file, the storage key and the chain are
/// all keyed by [instanceId].
class AppAuth {
  AppAuth({
    required this.instanceId,
    required this.url,
    required this.anonKey,
  });

  /// Which instance's session this owns. Also names the storage key and the
  /// lock file, so it must be safe in both.
  final String instanceId;
  final String url;
  final String anonKey;

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// Refresh this many seconds before the access token expires.
  static const int _refreshMarginSeconds = 300;

  final StreamController<AppAuthStatus> _events =
      StreamController<AppAuthStatus>.broadcast();

  // In-memory view of the current session.
  String? _accessToken;
  String? _refreshToken;
  int? _expiresAt; // epoch seconds
  Map<String, dynamic>? _claims;

  // Serialization of refreshes; the file lock serializes across isolates.
  Future<void> _chain = Future<void>.value();

  // A refresh token the server has rejected, and how many times running.
  String? _rejectedToken;
  int _rejectionCount = 0;

  /// How many consecutive rejections of the same refresh token it takes before
  /// the session is treated as genuinely dead.
  static const int _maxRejections = 3;

  String get _sessionKey => sessionStorageKey(instanceId);

  GotrueApi get _api => GotrueApi(url, anonKey);

  /// Emits when the user signs in/out of this instance, or its token is
  /// refreshed.
  Stream<AppAuthStatus> get events => _events.stream;

  bool get isLoggedIn => _refreshToken != null;

  Future<void> dispose() async {
    await _events.close();
  }

  /// Whether a session exists on this device for this instance, asked of
  /// storage rather than of this isolate's memory. True if storage read fails.
  Future<bool> hasStoredSession() async {
    if (_refreshToken != null) return true;
    try {
      final raw = await _storage.read(key: _sessionKey);
      if (raw == null || raw.isEmpty) return false;
      final session = jsonDecode(raw) as Map<String, dynamic>;
      final refresh = session['refresh_token'] as String?;
      return refresh != null && refresh.isNotEmpty;
    } catch (e) {
      debugPrint('AppAuth[$instanceId].hasStoredSession failed: $e');
      return true;
    }
  }

  String? get currentUserId => _claims?['sub'] as String?;
  String? get currentUserEmail => _claims?['email'] as String?;

  /// Load the persisted session into memory. Call once per isolate at startup,
  /// before building this instance's Supabase client. Only reads storage.
  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _sessionKey);
      if (raw != null && raw.isNotEmpty) {
        await _apply(jsonDecode(raw) as Map<String, dynamic>, persist: false);
      }
    } catch (e) {
      debugPrint('AppAuth[$instanceId].load failed: $e');
    }
  }

  /// The `accessToken` callback wired into this instance's Supabase client.
  /// Returns a valid JWT, refreshing if near expiry, or null when logged out.
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

  /// Register a new account.
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

        // No session in the response: either confirmation is required, or this
        // server auto-confirms without returning one
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
    _dropSession();
    _rejectedToken = null;
    _rejectionCount = 0;
    try {
      await _storage.delete(key: _sessionKey);
    } catch (e) {
      debugPrint('AppAuth[$instanceId].forgetSession failed: $e');
    }
  }

  /// Drop the in-memory session.
  void _dropSession() {
    _accessToken = _refreshToken = null;
    _expiresAt = null;
    _claims = null;
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
  // Refresh (single-flight, cross-isolate, per instance)
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
        debugPrint('AppAuth[$instanceId]: refresh skipped (offline)');
      } on GotrueAuthException catch (e) {
        await _handleRefreshRejection(e, used);
      }
    } catch (e) {
      debugPrint('AppAuth[$instanceId]._refreshLocked failed: $e');
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
      debugPrint('AppAuth[$instanceId]: refresh raced (${e.code}); '
          'adopted the session another isolate stored');
      _rejectedToken = null;
      _rejectionCount = 0;
      return;
    }

    if (isFatalRefreshCode(e.code)) {
      debugPrint(
          'AppAuth[$instanceId]: refresh rejected (${e.code}); signing out');
      await _clear();
      return;
    }

    _rejectionCount = (_rejectedToken == used) ? _rejectionCount + 1 : 1;
    _rejectedToken = used;

    if (_rejectionCount >= _maxRejections) {
      debugPrint('AppAuth[$instanceId]: refresh rejected (${e.code}) '
          '$_rejectionCount times running; signing out');
      await _clear();
      return;
    }

    debugPrint('AppAuth[$instanceId]: refresh failed '
        '(${e.code}, attempt $_rejectionCount); '
        'keeping the session and retrying later');
  }

  Future<void> _reloadFromStore() async {
    try {
      final raw = await _storage.read(key: _sessionKey);
      if (raw == null || raw.isEmpty) {
        _dropSession();
        return;
      }
      await _apply(jsonDecode(raw) as Map<String, dynamic>, persist: false);
    } catch (_) {}
  }

  /// Apply a GoTrue session JSON to memory, and persist it if asked.
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
    // Stored in the exact GoTrue session shape so any isolate can reload it.
    if (persist) {
      await _storage.write(key: _sessionKey, value: jsonEncode(session));
    }
  }

  /// Drop the session and announce the sign-out.
  Future<void> _clear() async {
    await forgetSession();
    _events.add(AppAuthStatus.signedOut);
  }

  /// Best-effort cross-process exclusive lock, null when it can't be taken. The
  /// caller then adopts the persisted session rather than refreshing unlocked:
  /// with token rotation, a parallel refresh hands one of the two callers a
  /// spent-token rejection.
  ///
  /// The lock is per instance, so a server that is slow to answer a refresh
  /// cannot stall the refresh chain of any other.
  Future<RandomAccessFile?> _acquireLock() async {
    try {
      final file =
          File('${Directory.systemTemp.path}/krab_auth_$instanceId.lock');
      final raf = await file.open(mode: FileMode.write);
      try {
        await raf.lock(FileLock.exclusive).timeout(const Duration(seconds: 8));
        return raf;
      } catch (e) {
        await raf.close();
        debugPrint('AppAuth[$instanceId]: proceeding without lock: $e');
        return null;
      }
    } catch (e) {
      debugPrint('AppAuth[$instanceId]: lock unavailable: $e');
      return null;
    }
  }
}
