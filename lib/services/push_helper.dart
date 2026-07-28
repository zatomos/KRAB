import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/instance/instance_config.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/instance/krab_instance.dart';
import 'package:krab/services/push_handler.dart';

/// Push delivery over Firebase Cloud Messaging.
///
/// Registration is per instance: each backend has its own Firebase project, so
/// each gets the token issued for its own sender and stores it against its own
/// user row.
///
/// Firebase itself is still brought up once, for the active instance's project.
/// Serving several at once needs a secondary [FirebaseApp] per instance, which
/// is the phase 2 work — until then, an instance whose FCM config differs from
/// the one Firebase came up with cannot be registered, and says so.
class PushHelper {
  static bool _initialized = false;
  static bool _handlersWired = false;

  /// The instance whose FCM project Firebase was initialised from.
  static KrabInstance? _firebaseInstance;

  static StreamSubscription<InstanceAuthEvent>? _authSubscription;
  static StreamSubscription<String>? _tokenRefreshSubscription;
  static StreamSubscription<RemoteMessage>? _onMessageSubscription;

  /// The user each instance's token has been stored for, so a second user
  /// signing in on this device stores a token of their own.
  static final Map<String, String> _savedForUser = {};
  static final Map<String, String> _savedToken = {};

  /// Brings Firebase up from the active instance's cached config and wires the
  /// FCM callbacks.
  static Future<void> initialize({required bool background}) async {
    if (background) return;

    if (!_initialized) {
      _initialized = true;
      // Every instance's sign-ins, not just one session's: whichever server the
      // user signs into needs this device's token.
      _authSubscription =
          InstanceRegistry.instance.authEvents.listen((event) async {
        if (event.status == AppAuthStatus.signedIn) {
          await ensureRegistered(event.instance);
        }
      });
    }

    final instance = InstanceRegistry.instance.active;
    if (instance == null) return;

    // Config may already be cached from a previous run.
    if (await _ensureFirebase(instance)) {
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
    _savedForUser.clear();
    _savedToken.clear();
  }

  /// Fetches this device's FCM token for [instance] and stores it against the
  /// user signed into that instance.
  ///
  /// Called both before and after a login, so it copes with arriving with no
  /// session yet and with being called again once there is one.
  static Future<bool> ensureRegistered(KrabInstance instance) async {
    try {
      // Instance config may have only just arrived; bring Firebase up now and
      // wire the callbacks that could not be set before.
      if (!await _ensureFirebase(instance)) {
        debugPrint('Push: no FCM config for ${instance.id} yet');
        return false;
      }
      _wireHandlers();

      if (instance.auth.currentUserId == null) {
        debugPrint('Push: no session on ${instance.id}; '
            'will register on sign-in');
        return false;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        debugPrint('Push: no FCM token available');
        return false;
      }
      return _saveToken(instance, token);
    } catch (e, st) {
      debugPrint('Push: ensureRegistered failed: $e\n$st');
      return false;
    }
  }

  /// Removes the token from FCM and forgets what we stored, on logout.
  ///
  /// The token is only deleted from FCM when the instance losing it is the one
  /// Firebase is running as; another instance's registration is not ours to
  /// revoke.
  static Future<void> unregister(KrabInstance instance) async {
    try {
      if (_firebaseInstance?.id == instance.id) {
        await FirebaseMessaging.instance.deleteToken();
      }
    } catch (e) {
      debugPrint('Push: deleteToken failed: $e');
    }
    _savedForUser.remove(instance.id);
    _savedToken.remove(instance.id);
  }

  /// Initialises Firebase from an instance's cached config. Returns whether
  /// Firebase is usable for that instance: false when it published no FCM
  /// config, and false when Firebase is already up as a *different* instance.
  static Future<bool> _ensureFirebase(KrabInstance instance) async {
    final existing = _firebaseInstance;
    if (existing != null) {
      if (existing.id == instance.id) return true;
      // One FirebaseApp, one sender. Phase 2 gives each instance its own.
      if (!_sameProject(existing.config, instance.config)) {
        debugPrint('Push: Firebase is up as ${existing.id}; '
            '${instance.id} cannot register until secondary apps land');
        return false;
      }
      return true;
    }

    if (!instance.config.hasFcm) return false;

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: _firebaseOptions(instance));
      }
      _firebaseInstance = instance;
      return true;
    } catch (e) {
      debugPrint('Push: Firebase init failed: $e');
      return false;
    }
  }

  /// Whether two instances are served by the same Firebase project, in which
  /// case one FirebaseApp covers both.
  static bool _sameProject(InstanceConfig a, InstanceConfig b) =>
      a.fcmSenderId == b.fcmSenderId && a.fcmProjectId == b.fcmProjectId;

  static FirebaseOptions _firebaseOptions(KrabInstance instance) =>
      FirebaseOptions(
        apiKey: instance.config.fcmApiKey,
        appId: instance.config.fcmAppId,
        messagingSenderId: instance.config.fcmSenderId,
        projectId: instance.config.fcmProjectId,
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

    // A rotated token must reach every backend registered with it, or delivery
    // silently stops until the next launch.
    _tokenRefreshSubscription =
        FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      _savedForUser.clear();
      for (final instance in InstanceRegistry.instance.all) {
        if (instance.auth.isLoggedIn) await _saveToken(instance, token);
      }
    });
  }

  static Future<bool> _saveToken(KrabInstance instance, String token) async {
    final userId = instance.auth.currentUserId;
    if (userId == null) return false;
    if (_savedForUser[instance.id] == userId &&
        _savedToken[instance.id] == token) {
      return true;
    }

    final tail = _redactToken(token);
    final res = await instance.api.saveFcmToken(token: token);
    if (res.success) {
      _savedForUser[instance.id] = userId;
      _savedToken[instance.id] = token;
      debugPrint('Push: token saved for ${instance.id} ($tail)');
      await DebugNotifier.instance
          .notifyPushSubscriptionSaved('saved $tail (${instance.id})');
      return true;
    }

    debugPrint('Push: failed to save token for ${instance.id} '
        '($tail): ${res.error}');
    await DebugNotifier.instance
        .notifyPushSubscriptionFailed('$tail (${instance.id}): ${res.error}');
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
