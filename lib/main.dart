import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:home_widget/home_widget.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/app.dart';
import 'package:krab/app_globals.dart';
import 'package:krab/firebase_options.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/fcm_helper.dart';
import 'package:krab/services/feed_events.dart';
import 'package:krab/services/home_widget_status.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/notification_router.dart';
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/services/supabase_bootstrap.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/pages/login_page.dart';
import 'package:krab/user_preferences.dart';

void main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await dotenv.load(fileName: ".env");
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await UserPreferences().initPrefs();
    await DebugNotifier.instance.initialize();

    // Local notification tap handler
    await initCommentNotifications(onTap: handleLocalNotificationTap);
    pendingLocalNotificationPayload = await getLocalNotificationLaunchPayload();

    final supabaseOk = await initializeSupabaseIfNeeded();

    HomeWidgetStatus.instance.initialize();

    // WorkManager periodic widget refresh
    await Workmanager().initialize(workmanagerCallbackDispatcher);
    await scheduleWidgetRefresh(UserPreferences.widgetRefreshIntervalMinutes);

    // Background FCM
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // App launched from a home-screen widget tap
    pendingWidgetUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    HomeWidget.widgetClicked.listen(handleWidgetLaunch);

    // FCM permissions and auto-init
    final settings = await FirebaseMessaging.instance.requestPermission();
    debugPrint('FCM Authorization status: ${settings.authorizationStatus}');
    await FirebaseMessaging.instance.setAutoInitEnabled(true);

    if (supabaseOk) {
      await FcmHelper.initializeAndSyncToken();
      await ProfilePictureCache.of(Supabase.instance.client).hydrate();
      // Cache groups so the widget configure screen can offer a group filter
      await cacheUserGroupsForWidget();
      _listenToAuthEvents();
    } else {
      debugPrint('Skipping FCM/cache init, Supabase not initialized');
    }

    isAppInitialized = true;

    _listenToForegroundMessages();

    runApp(MyApp(navigatorKey: navigatorKey));
  } catch (e, st) {
    debugPrint('Error starting app: $e');
    debugPrint('Stack trace: $st');
    runApp(MyApp(navigatorKey: navigatorKey));
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

/// Handle FCM messages that arrive while the app is in the foreground.
void _listenToForegroundMessages() {
  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    try {
      debugPrint("Foreground FCM: ${message.messageId}, data=${message.data}");
      final msgType = message.data['type'];
      if (msgType == 'new_image') {
        await dispatchImageNotification(message.data);
        await updateHomeWidget();
        // Let an open feed surface a new photos pill without a refresh
        FeedEvents.instance.notifyNewImage(NewImageEvent(
          imageId: message.data['image_id'] ?? '',
          groupId: message.data['group_id'],
        ));
      } else if (msgType == 'new_comment' ||
          msgType == 'group_comment' ||
          msgType == 'comment_reply') {
        await dispatchCommentNotification(message.data, msgType);
      } else if (msgType == 'new_reaction') {
        await dispatchReactionNotification(message.data);
      } else if (msgType == 'image_deleted') {
        await cancelImageNotification(message.data['image_id'] ?? '');
        await updateHomeWidget();
      }
    } catch (e, st) {
      debugPrint('Error handling foreground message: $e');
      debugPrint(st.toString());
      if (scaffoldMessengerKey.currentContext != null) {
        showSnackBar('Error updating widget', color: Colors.red);
      }
    }
  });
}
