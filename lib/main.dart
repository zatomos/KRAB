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
import 'package:krab/services/launch_router.dart';
import 'package:krab/services/push_handler.dart';
import 'package:krab/services/cache/profile_picture_cache.dart';
import 'package:krab/services/push_helper.dart';
import 'package:krab/services/storage_cleanup.dart';
import 'package:krab/services/supabase_bootstrap.dart';
import 'package:krab/services/upload_outbox.dart';
import 'package:krab/pages/login_page.dart';
import 'package:krab/user_preferences.dart';

/// Entry point for both the app and a push delivery.
void main(List<String> args) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await UserPreferences().initPrefs();
    await DebugNotifier.instance.initialize();
    await initCommentNotifications(onTap: handleLocalNotificationTap);

    final supabaseOk = await initializeSupabaseIfNeeded();
    await PushHelper.initialize(background: false);

    pendingLocalNotificationPayload = await getLocalNotificationLaunchPayload();
    await requestNotificationPermission();

    HomeWidgetStatus.instance.initialize();
    await Workmanager().initialize(workmanagerCallbackDispatcher);
    await scheduleWidgetRefresh(UserPreferences.widgetRefreshIntervalMinutes);

    // App launched from a home-screen widget tap
    pendingWidgetUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    HomeWidget.widgetClicked.listen(handleWidgetLaunch);

    isAppInitialized = true;

    runApp(MyApp(navigatorKey: navigatorKey));

    unawaited(StorageCleanup.sweep());

    if (supabaseOk) {
      _listenToAuthEvents();
      unawaited(updateHomeWidget());
      unawaited(_warmUpFromNetwork());
    } else {
      debugPrint('Skipping push/cache init, Supabase not initialized');
    }
  } catch (e, st) {
    debugPrint('Error starting app: $e');
    debugPrint('Stack trace: $st');
    runApp(MyApp(navigatorKey: navigatorKey));
  }
}

/// Network work that runs once the UI is up.
Future<void> _warmUpFromNetwork() async {
  try {
    await fetchInstanceConfig();
    await PushHelper.ensureRegistered();
    await ProfilePictureCache.of(Supabase.instance.client).hydrate();
    // So the widget's configure screen can offer a group filter.
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
        // Say so on the widget now. Otherwise it keeps showing the photos from
        // just before the sign-out until some later refresh happens to notice.
        unawaited(updateHomeWidget());
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
        // Before the notifier, not after: this clears the signed-out overlay and
        // refills the widget, and it should not be reachable only if everything
        // above it succeeds. The sign-out branch has it first for the same
        // reason.
        unawaited(updateHomeWidget());
        await DebugNotifier.instance.notifyAuthStateChanged('signedIn');
        break;
    }
  });
}
