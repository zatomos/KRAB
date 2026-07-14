import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:home_widget/home_widget.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/app.dart';
import 'package:krab/app_globals.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/home_widget_status.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/notification_router.dart';
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/services/push_helper.dart';
import 'package:krab/services/supabase_bootstrap.dart';
import 'package:krab/services/upload_outbox.dart';
import 'package:krab/pages/login_page.dart';
import 'package:krab/user_preferences.dart';

/// Entry point for both the app and a push delivery.
void main(List<String> args) async {
  final background = args.contains('--unifiedpush-bg');

  try {
    WidgetsFlutterBinding.ensureInitialized();
    await UserPreferences().initPrefs();
    await DebugNotifier.instance.initialize();

    // Local notification tap handler
    await initCommentNotifications(onTap: handleLocalNotificationTap);

    final supabaseOk = await initializeSupabaseIfNeeded();

    // Wires the push callbacks
    await PushHelper.initialize(background: background);

    if (background) {
      isAppInitialized = true;
      return;
    }

    pendingLocalNotificationPayload = await getLocalNotificationLaunchPayload();

    // Check for notification permissions
    await requestNotificationPermission();

    HomeWidgetStatus.instance.initialize();

    // WorkManager periodic widget refresh
    await Workmanager().initialize(workmanagerCallbackDispatcher);
    await scheduleWidgetRefresh(UserPreferences.widgetRefreshIntervalMinutes);

    // App launched from a home-screen widget tap
    pendingWidgetUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    HomeWidget.widgetClicked.listen(handleWidgetLaunch);

    isAppInitialized = true;

    runApp(MyApp(navigatorKey: navigatorKey));

    if (supabaseOk) {
      _listenToAuthEvents();
      unawaited(_warmUpFromNetwork());
    } else {
      debugPrint('Skipping push/cache init, Supabase not initialized');
    }
  } catch (e, st) {
    debugPrint('Error starting app: $e');
    debugPrint('Stack trace: $st');
    if (!background) {
      runApp(MyApp(navigatorKey: navigatorKey));
    }
  }
}

/// Network work that runs once the UI is up.
Future<void> _warmUpFromNetwork() async {
  try {
    // Re-read this instance's public settings on every launch. Cached.
    await fetchInstanceConfig();

    // Subscribes through a distributor and hands the endpoint to
    // this instance's backend.
    await PushHelper.ensureRegistered();
    await ProfilePictureCache.of(Supabase.instance.client).hydrate();
    // Cache groups so the widget configure screen can offer a group filter
    await cacheUserGroupsForWidget();
    // Photos queued while offline go out as soon as we're up again.
    await UploadOutbox.instance.flush();
  } catch (e, st) {
    debugPrint('Warm-up failed: $e\n$st');
  }
}

/// React to session changes: surface debug notifications and bounce to the
/// login page on an unexpected sign-out.
void _listenToAuthEvents() {
  AppAuth.instance.events.listen((status) async {
    debugPrint('Auth state changed: $status');
    switch (status) {
      case AppAuthStatus.signedOut:
        if (DebugNotifier.instance.isIntentionalLogout) {
          await DebugNotifier.instance.notifyAuthSignedOut(unexpected: false);
        } else {
          await DebugNotifier.instance.notifyAuthSignedOut();
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginPage()),
            (route) => false,
          );
        }
        break;
      case AppAuthStatus.tokenRefreshed:
        await DebugNotifier.instance.notifyAuthTokenRefreshed();
        break;
      case AppAuthStatus.signedIn:
        await DebugNotifier.instance.notifyAuthStateChanged('signedIn');
        // Now that we're authenticated, refresh so the widget fills in.
        unawaited(updateHomeWidget());
        break;
    }
  });
}

