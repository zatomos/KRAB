import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/supabase_bootstrap.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/pages/image_feed_page.dart';

/// Waits for the navigator to mount and returns it, or null if it never comes up
Future<NavigatorState?> _awaitNavigator() async {
  try {
    return await navigatorReady.future.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    return navigatorKey.currentState;
  }
}

/// Handle a tap on a home-screen widget. The URI is emitted by the native
/// widget providers via the home_widget plugin:
///   krab://open?imageId=ID     open the all-groups gallery on that image
///   krab://open?action=camera  bring the camera to the front
Future<void> handleWidgetLaunch(Uri? uri) async {
  if (uri == null) return;
  debugPrint('Handling widget launch: $uri');
  try {
    final nav = await _awaitNavigator();
    if (nav == null) return;

    // Only act on an authenticated session; otherwise the app just opens
    if (!isSupabaseInitialized || !AppAuth.instance.isLoggedIn) {
      return;
    }

    if (uri.queryParameters['action'] == 'camera') {
      nav.popUntil((route) => route.isFirst);
      return;
    }

    final imageId = uri.queryParameters['imageId'];
    if (imageId != null && imageId.isNotEmpty) {
      nav.push(
        MaterialPageRoute(
          builder: (_) => ImageFeedPage(imageId: imageId),
        ),
      );
    }
  } catch (e, st) {
    debugPrint('Error handling widget launch: $e\n$st');
  }
}

Future<void> handleLocalNotificationTap(String payload) async {
  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final type = data['type'] as String? ?? '';
    final groupId = data['group_id'] as String? ?? '';
    final imageId = data['image_id'] as String? ?? '';

    final nav = await _awaitNavigator();
    if (nav == null) return;

    // Reactions aren't tied to a group: open the all-groups gallery on the image
    if (type == 'new_reaction') {
      if (imageId.isEmpty) return;
      nav.push(
        MaterialPageRoute(builder: (_) => ImageFeedPage(imageId: imageId)),
      );
      return;
    }

    if (groupId.isEmpty) return;
    final groupResponse = await getGroupDetails(groupId);
    if (!groupResponse.success || groupResponse.data == null) return;

    nav.push(
      MaterialPageRoute(
        builder: (_) => ImageFeedPage(
          group: groupResponse.data!,
          imageId: imageId,
        ),
      ),
    );
  } catch (e) {
    debugPrint('Error handling local notification tap: $e');
  }
}

@pragma('vm:entry-point')
void workmanagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      await bootstrapBackgroundIsolate();

      // Piggyback a throttled app-update check on this wakeup
      await UpdateService.maybeCheckAndNotifyUpdate();

      final supabaseOk = await initializeBackgroundSupabase();
      if (!supabaseOk) {
        debugPrint('WorkManager: Supabase init failed, skipping widget update');
        return Future.value(false);
      }
      if (await AppAuth.instance.getValidToken() == null) {
        debugPrint('WorkManager: no valid session, skipping widget update');
        return Future.value(true);
      }

      await updateHomeWidget();
      return Future.value(true);
    } catch (e, st) {
      debugPrint('WorkManager task failed: $e\n$st');
      return Future.value(false);
    }
  });
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Handling background message: ${message.messageId}');
  debugPrint('Background data: ${message.data}');

  final type = message.data['type'];
  if (type != 'new_image' &&
      type != 'new_comment' &&
      type != 'group_comment' &&
      type != 'comment_reply' &&
      type != 'new_reaction' &&
      type != 'group_reaction' &&
      type != 'image_deleted') {
    debugPrint('Background message type "$type" not handled, skipping');
    return;
  }

  try {
    await bootstrapBackgroundIsolate();
    await DebugNotifier.instance.notifyBackgroundTaskStarted();

    final supabaseOk = await initializeBackgroundSupabase();
    if (!supabaseOk) {
      debugPrint('Supabase not initialized (background)');
      await DebugNotifier.instance
          .notifySupabaseInitFailed('Background: Supabase init failed');
      return;
    }

    if (await AppAuth.instance.getValidToken() == null) {
      await DebugNotifier.instance.notifyBackgroundTaskFailed(
          'Background session unavailable, reopen the app to re-authenticate');
      return;
    }

    if (type == 'new_image') {
      await dispatchImageNotification(message.data);
      await updateHomeWidget();
    } else if (type == 'image_deleted') {
      // The image is gone, clear any standing notification for it and refresh
      // the widget so it drops out
      await cancelImageNotification(message.data['image_id'] ?? '');
      await updateHomeWidget();
    } else if (type == 'new_reaction' || type == 'group_reaction') {
      await dispatchReactionNotification(message.data, type);
    } else {
      await dispatchCommentNotification(message.data, type);
    }

    debugPrint('Background message processed successfully');
    await DebugNotifier.instance.notifyBackgroundTaskCompleted();
  } catch (e, st) {
    debugPrint('Error in background handler: $e');
    debugPrint(st.toString());
    await DebugNotifier.instance.notifyBackgroundTaskFailed('$e');
  }
}
