import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/push_handler.dart';
import 'package:krab/user_preferences.dart';

/// Push delivery over Firebase Cloud Messaging.
class PushHelper {
  static bool _initialized = false;
  static bool _firebaseReady = false;
  static bool _handlersWired = false;
  static StreamSubscription<AppAuthStatus>? _authSubscription;
  static StreamSubscription<String>? _tokenRefreshSubscription;
  static StreamSubscription<RemoteMessage>? _onMessageSubscription;

  /// The user the current token has been stored for, so a second user signing
  /// in on this device stores a token of their own.
  static String? _savedForUser;
  static String? _savedToken;

  /// Brings Firebase up from cached config and wires the FCM callbacks.
  static Future<void> initialize({required bool background}) async {
    if (background) return;

    if (!_initialized) {
      _initialized = true;
      _authSubscription = AppAuth.instance.events.listen((status) async {
        if (status == AppAuthStatus.signedIn) {
          await ensureRegistered();
        }
      });
    }

    // Config may already be cached from a previous run;
    if (await _ensureFirebase()) {
      _wireHandlers();
    }
  }

  static Future<void> dispose() async {
    await _authSubscription?.cancel();
    _authSubscription = null;
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    await _onMessageSubscription?.cancel();
    _onMessageSubscription = null;
    _initialized = false;
    _handlersWired = false;
    _savedForUser = null;
    _savedToken = null;
  }

  /// Fetches this device's FCM token and stores it against the signed-in user.
  ///
  /// Called both before and after a login, so it copes with arriving with no
  /// session yet and with being called again once there is one.
  static Future<bool> ensureRegistered() async {
    try {
      // Instance config may have only just arrived; bring Firebase up now and
      // wire the callbacks that could not be set before.
      if (!await _ensureFirebase()) {
        debugPrint('Push: no FCM config for this instance yet');
        return false;
      }
      _wireHandlers();

      if (AppAuth.instance.currentUserId == null) {
        debugPrint('Push: no session; will register on sign-in');
        return false;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        debugPrint('Push: no FCM token available');
        return false;
      }
      return _saveToken(token);
    } catch (e, st) {
      debugPrint('Push: ensureRegistered failed: $e\n$st');
      return false;
    }
  }

  /// Removes the token from FCM and forgets what we stored, on logout.
  static Future<void> unregister() async {
    try {
      if (_firebaseReady) await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('Push: deleteToken failed: $e');
    }
    _savedForUser = null;
    _savedToken = null;
  }

  /// Initialises Firebase from the cached per-instance config. Returns whether
  /// Firebase is usable; false when the instance has published no FCM config.
  static Future<bool> _ensureFirebase() async {
    if (_firebaseReady) return true;
    if (!UserPreferences.hasFcmConfig) return false;

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: _firebaseOptions());
      }
      _firebaseReady = true;
      return true;
    } catch (e) {
      debugPrint('Push: Firebase init failed: $e');
      return false;
    }
  }

  static FirebaseOptions _firebaseOptions() => FirebaseOptions(
        apiKey: UserPreferences.fcmApiKey,
        appId: UserPreferences.fcmAppId,
        messagingSenderId: UserPreferences.fcmSenderId,
        projectId: UserPreferences.fcmProjectId,
      );

  /// Wires the foreground-message and token-refresh listeners.
  static void _wireHandlers() {
    if (_handlersWired) return;
    _handlersWired = true;

    // Delivery while the app is backgrounded or killed runs in a dedicated
    // isolate through this top-level handler.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // The OS does not post a notification for a data message while the app is
    // in the foreground, so route it through the same handler as the rest.
    _onMessageSubscription = FirebaseMessaging.onMessage.listen((message) {
      handlePushPayload(_stringData(message.data), background: false);
    });

    // A rotated token must reach the backend, or delivery silently stops until
    // the next launch.
    _tokenRefreshSubscription =
        FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      _savedForUser = null;
      _saveToken(token);
    });
  }

  static Future<bool> _saveToken(String token) async {
    final userId = AppAuth.instance.currentUserId;
    if (userId == null) return false;
    if (_savedForUser == userId && _savedToken == token) return true;

    final tail = _redactToken(token);
    final res = await saveFcmToken(token: token);
    if (res.success) {
      _savedForUser = userId;
      _savedToken = token;
      debugPrint('Push: token saved ($tail)');
      await DebugNotifier.instance.notifyPushSubscriptionSaved('saved $tail');
      return true;
    }

    debugPrint('Push: failed to save token ($tail): ${res.error}');
    await DebugNotifier.instance
        .notifyPushSubscriptionFailed('$tail: ${res.error}');
    return false;
  }

  /// A short, non-secret tail of a token, enough to correlate a client-side
  /// save with the row the backend holds without logging the whole token.
  static String _redactToken(String token) {
    if (token.length <= 12) return token;
    return '...${token.substring(token.length - 12)}';
  }

  static Map<String, String> _stringData(Map<String, dynamic> data) =>
      data.map((k, v) => MapEntry(k, '$v'));
}
