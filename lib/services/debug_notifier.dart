import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DebugNotifier {
  static final DebugNotifier _instance = DebugNotifier._internal();
  static DebugNotifier get instance => _instance;

  DebugNotifier._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _enabled = false;

  /// Flag to track intentional logout
  bool _isIntentionalLogout = false;

  static const String _prefKey = 'debugNotifications';
  static const String _channelId = 'krab_debug';
  static const String _channelName = 'Debug Notifications';
  static const String _channelDescription =
      'Debug notifications for diagnosing widget and auth issues';

  int _notificationId = 0;

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Load preference
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? false;

      // Initialize notifications plugin
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidSettings);

      await _notifications.initialize(settings: initSettings);

      // Create the notification channel (Android 8+)
      final androidPlugin =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.low,
            playSound: false,
            enableVibration: false,
          ),
        );
      }

      _initialized = true;
      debugPrint('DebugNotifier: initialized (enabled=$_enabled)');
    } catch (e, st) {
      debugPrint('DebugNotifier: initialization failed: $e');
      debugPrint(st.toString());
    }
  }

  /// Check if debug notifications are enabled
  bool get isEnabled => _enabled;

  /// Enable or disable debug notifications
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
    debugPrint('DebugNotifier: enabled=$_enabled');
  }

  /// Show a debug notification (only if enabled)
  Future<void> _notify(String title, String body) async {
    if (!_enabled) return;
    if (!_initialized) {
      debugPrint('DebugNotifier: not initialized, skipping notification');
      return;
    }

    try {
      final id = _notificationId++;
      await _notifications.show(
        id: id,
        title: '[Debug] $title',
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.low,
            priority: Priority.low,
            playSound: false,
            enableVibration: false,
            autoCancel: true,
          ),
        ),
      );
      debugPrint('DebugNotifier: showed notification #$id: $title - $body');
    } catch (e) {
      debugPrint('DebugNotifier: failed to show notification: $e');
    }
  }

  // --- Widget Update Events ---

  Future<void> notifyWidgetUpdateStarted() async {
    await _notify('Widget', '1/7 Starting update...');
  }

  Future<void> notifyWidgetStep(int step, int total, String message) async {
    await _notify('Widget', '$step/$total $message');
  }

  Future<void> notifyWidgetUpdateSuccess(String? imageId) async {
    await _notify('Widget', '7/7 Done: ${imageId ?? "unknown"}');
  }

  Future<void> notifyWidgetUpdateFailed(String reason) async {
    await _notify('Widget Failed', reason);
  }

  // --- Auth Events ---

  /// Call this before intentional logout to prevent "unexpected signout" notification
  void markIntentionalLogout() {
    _isIntentionalLogout = true;
  }

  /// Reset the intentional logout flag
  void resetIntentionalLogout() {
    _isIntentionalLogout = false;
  }

  /// Check if this was an intentional logout
  bool get isIntentionalLogout => _isIntentionalLogout;

  Future<void> notifyAuthStateChanged(String event) async {
    await _notify('Auth', event);
  }

  Future<void> notifyAuthSignedOut({bool unexpected = true}) async {
    if (unexpected && !_isIntentionalLogout) {
      await _notify('Auth', 'Signed out unexpectedly');
    } else {
      // Reset flag after intentional logout
      _isIntentionalLogout = false;
      debugPrint('DebugNotifier: intentional logout, skipping notification');
    }
  }

  Future<void> notifyAuthTokenRefreshed() async {
    await _notify('Auth', 'Token refreshed');
  }

  // --- Background Task Events ---

  Future<void> notifyBackgroundTaskStarted() async {
    await _notify('Background', 'Background handler triggered');
  }

  Future<void> notifyBackgroundTaskCompleted() async {
    await _notify('Background', 'Background task completed');
  }

  Future<void> notifyBackgroundTaskFailed(String reason) async {
    await _notify('Background Failed', reason);
  }

  // --- FCM Events ---

  Future<void> notifyFcmTokenPushFailed(String error) async {
    await _notify('FCM Sync Failed', error);
  }

  Future<void> notifyFcmTokenPushed() async {
    await _notify('FCM', 'Token synced successfully');
  }

  // --- Supabase Events ---

  Future<void> notifySupabaseInitFailed(String error) async {
    await _notify('Supabase Init Failed', error);
  }
}
