import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/instance/krab_instance.dart';
import 'package:krab/services/push_handler.dart';

/// Push delivery over Firebase Cloud Messaging.
///
/// Registration is per instance: each backend has its own Firebase project, so
/// each gets the token minted for its own sender and stores that against its
/// own user row. Only a sender the device is registered with can send the
/// high-priority message that wakes a dozing device, so a server sharing
/// another's token would simply never arrive.
///
/// Those tokens come from the native side over _channel, because
/// `firebase_messaging` supports the default FirebaseApp only.
/// Delivery still lands in the one messaging service whatever sender it came
/// from, so what arrives is routed in Dart on the instance the payload names.
class PushHelper {
  static const MethodChannel _channel = MethodChannel('krab/push');

  static bool _initialized = false;
  static bool _handlersWired = false;

  /// Whether the default FirebaseApp is up.
  static bool _firebaseReady = false;

  static StreamSubscription<InstanceAuthEvent>? _authSubscription;
  static StreamSubscription<String>? _removalSubscription;
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

      // Every instance holds its own named FirebaseApp, so disconnecting one
      // leaves the others' tokens alone.
      _removalSubscription = InstanceRegistry.instance.removals.listen((id) {
        _savedForUser.remove(id);
        _savedToken.remove(id);
        _forgetTokens();
      });
    }

    // Match FirebaseApp
    final instance =
        InstanceRegistry.instance.all.where((i) => i.config.hasFcm).firstOrNull;
    if (instance == null) return;

    // Config may already be cached from a previous run.
    if (await _ensureFirebase(instance)) {
      _wireHandlers();
    }
  }

  static Future<void> dispose() async {
    await _authSubscription?.cancel();
    _authSubscription = null;
    await _removalSubscription?.cancel();
    _removalSubscription = null;
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    await _onMessageSubscription?.cancel();
    _onMessageSubscription = null;
    _initialized = false;
    _handlersWired = false;
    _firebaseReady = false;
    _savedForUser.clear();
    _savedToken.clear();
    _forgetTokens();
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

      final token = await _tokenFor(instance);
      if (token == null) {
        debugPrint('Push: no FCM token for ${instance.id}');
        return false;
      }
      return await _saveToken(instance, token);
    } catch (e, st) {
      debugPrint('Push: ensureRegistered failed: $e\n$st');
      return false;
    }
  }

  /// This device's token for every connected instance, keyed by instance id.
  static Future<Map<String, String>>? _tokensFuture;

  static Future<Map<String, String>> _instanceTokens() =>
      _tokensFuture ??= _fetchInstanceTokens();

  /// How long to keep asking FCM for a sender it has not minted a token for yet
  static const List<Duration> _tokenRetryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  /// This device's token for the instance, waiting through a registration that
  /// has not completed yet.
  static Future<String?> _tokenFor(KrabInstance instance) async {
    for (var attempt = 0;; attempt++) {
      final future = _instanceTokens();
      final token = (await future)[instance.id];
      if (token != null) return token;
      if (identical(_tokensFuture, future)) _tokensFuture = null;

      if (attempt >= _tokenRetryDelays.length) return null;
      debugPrint('Push: no token for ${instance.id} yet, retrying');
      await Future<void>.delayed(_tokenRetryDelays[attempt]);
    }
  }

  static Future<Map<String, String>> _fetchInstanceTokens() async {
    try {
      final tokens =
          await _channel.invokeMapMethod<String, String>('instanceTokens');
      return tokens ?? const {};
    } on MissingPluginException {
      debugPrint('Push: no native token provider on this platform');
      return const {};
    } catch (e) {
      _tokensFuture = null;
      debugPrint('Push: could not read the instance tokens: $e');
      return const {};
    }
  }

  /// Forget the cached tokens, so the next registration asks FCM afresh.
  static void _forgetTokens() => _tokensFuture = null;

  /// Forgets what we stored for an instance, on logout.
  ///
  /// The token itself is left alone: it belongs to this device and this
  /// server's sender, and deleting it would also stop delivery for any other
  /// account still signed into the same server.
  static Future<void> unregister(KrabInstance instance) async {
    _savedForUser.remove(instance.id);
    _savedToken.remove(instance.id);
  }

  /// Makes sure Firebase is usable for this instance. False when it
  /// has published no FCM config, which is the one case nothing
  /// can be done about here.
  ///
  /// The native side owns a named FirebaseApp per instance; this only ensures the
  /// default app exists, since that is the one the messaging plugin's streams
  /// hang off.
  static Future<bool> _ensureFirebase(KrabInstance instance) async {
    if (!instance.config.hasFcm) return false;
    if (_firebaseReady) return true;

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: _firebaseOptions(instance));
      }
      _firebaseReady = true;
      return true;
    } catch (e) {
      debugPrint('Push: Firebase init failed: $e');
      return false;
    }
  }

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
      handlePushPayload(
        _stringData(message.data),
        background: false,
        senderId: message.senderId,
      );
    });

    // A rotated token must reach the backend it belongs to, or delivery
    // silently stops until the next launch. FCM rotates per sender, and this
    // stream only speaks for the default app, so re-ask for all of them rather
    // than writing this one token everywhere.
    _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
        .listen((_) async => _reregisterEverything());
  }

  /// Throw away every token this device holds and ask for them again, then store
  /// each with the server it belongs to.
  static Future<void> _reregisterEverything() async {
    _savedForUser.clear();
    _savedToken.clear();
    _forgetTokens();
    final tokens = await _instanceTokens();
    for (final instance in InstanceRegistry.instance.all) {
      if (!instance.auth.isLoggedIn) continue;
      final token = tokens[instance.id];
      if (token != null) await _saveToken(instance, token);
    }
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
