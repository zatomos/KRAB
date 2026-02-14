import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../UserPreferences.dart';
import 'debug_notifier.dart';

class FcmHelper {
  static bool _listenersWired = false;
  static StreamSubscription<String>? _tokenRefreshSubscription;
  static StreamSubscription<AuthState>? _authStateSubscription;

  /// Dispose all subscriptions
  static Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();
    await _authStateSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _authStateSubscription = null;
    _listenersWired = false;
    debugPrint('FCM: disposed');
  }

  /// Call this after Supabase is initialized
  static Future<void> initializeAndSyncToken() async {
    try {
      if (UserPreferences.supabaseUrl.isEmpty ||
          UserPreferences.supabaseAnonKey.isEmpty) {
        debugPrint('FCM: Supabase config missing; skipping FCM token sync.');
        return;
      }

      final messaging = FirebaseMessaging.instance;

      final settings = await messaging.requestPermission();
      debugPrint('FCM: permission status = ${settings.authorizationStatus}');

      await FirebaseMessaging.instance.setAutoInitEnabled(true);

      // Get the token and push it if logged in
      final token = await messaging.getToken();
      debugPrint('FCM: current token = $token');
      if (token != null) {
        await _pushTokenIfLoggedIn(token);
      }

      if (!_listenersWired) {
        // Cancel any existing subscriptions before re-wiring
        await dispose();
        _listenersWired = true;

        // Token refresh
        _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
          debugPrint('FCM: token refreshed = $newToken');
          await _pushTokenIfLoggedIn(newToken);
        });

        // Auth changes
        _authStateSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((_) async {
          final t = await FirebaseMessaging.instance.getToken();
          debugPrint('FCM: auth state changed; pushing latest token = $t');
          if (t != null) {
            await _pushTokenIfLoggedIn(t);
          }
        });
      }
    } catch (e, st) {
      debugPrint('FCM: initializeAndSyncToken error: $e');
      debugPrint('$st');
    }
  }

  static Future<void> _pushTokenIfLoggedIn(String token) async {
    try {
      if (UserPreferences.supabaseUrl.isEmpty ||
          UserPreferences.supabaseAnonKey.isEmpty) {
        debugPrint('FCM: Supabase not configured; skipping token push.');
        return;
      }
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        debugPrint('FCM: no logged-in user; skipping token push.');
        return;
      }

      await Supabase.instance.client.from('Users').upsert({
        'id': user.id,
        'fcm_token': token,
      });
      debugPrint('FCM: token pushed to Supabase for user ${user.id}');
      await DebugNotifier.instance.notifyFcmTokenPushed();
    } catch (e, st) {
      debugPrint('FCM: failed to push token: $e');
      debugPrint('$st');
      await DebugNotifier.instance.notifyFcmTokenPushFailed('$e');
    }
  }
}
