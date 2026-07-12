import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/feed_events.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/supabase_bootstrap.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/services/upload_outbox.dart';
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

    // Nothing here belongs to a single group: a reaction isn't tied to one at
    // all, and a photo delivered to the user through several groups at once has
    // no one group to open. dispatchImageNotification leaves group_id empty to
    // say so. Both open the all-groups gallery, on the image.
    if (type == 'new_reaction' || (type == 'new_image' && groupId.isEmpty)) {
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

      final isOutboxFlush = taskName == outboxFlushTask;

      // Piggyback a throttled app-update check on the periodic wakeup
      if (!isOutboxFlush) {
        await UpdateService.maybeCheckAndNotifyUpdate();
      }

      final supabaseOk = await initializeBackgroundSupabase();
      if (!supabaseOk) {
        debugPrint('WorkManager: Supabase init failed, nothing to do');
        return Future.value(false);
      }
      if (await AppAuth.instance.getValidToken() == null) {
        // Queued photos keep until the user reopens the app and
        // re-authenticates.
        debugPrint('WorkManager: no valid session, skipping');
        return Future.value(true);
      }

      // Reporting failure here is what earns the WorkManager retry, so the
      // queue keeps draining on its own once the connection is back.
      if (isOutboxFlush) {
        return Future.value(await UploadOutbox.instance.flush());
      }

      await UploadOutbox.instance.flush();
      await updateHomeWidget();
      return Future.value(true);
    } catch (e, st) {
      debugPrint('WorkManager task failed: $e\n$st');
      return Future.value(false);
    }
  });
}

/// Handles a decrypted push payload.
@pragma('vm:entry-point')
Future<void> handlePushPayload(
  Map<String, String> data, {
  required bool background,
}) async {
  final type = data['type'];
  debugPrint('Push: handling type="$type" (background=$background)');

  if (type != 'new_image' &&
      type != 'new_comment' &&
      type != 'group_comment' &&
      type != 'comment_reply' &&
      type != 'new_reaction' &&
      type != 'group_reaction' &&
      type != 'image_deleted') {
    debugPrint('Push message type "$type" not handled, skipping');
    return;
  }

  try {
    if (background) {
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
    }

    if (type == 'new_image') {
      await dispatchImageNotification(data);
      await updateHomeWidget();
      if (!background) {
        // Let an open feed surface a new photos pill without a refresh
        FeedEvents.instance.notifyNewImage(NewImageEvent(
          imageId: data['image_id'] ?? '',
          groupId: data['group_id'],
        ));
      }
    } else if (type == 'image_deleted') {
      // The image is gone, clear any standing notification for it and refresh
      // the widget so it drops out
      await cancelImageNotification(data['image_id'] ?? '');
      await updateHomeWidget();
    } else if (type == 'new_reaction' || type == 'group_reaction') {
      // Non-null: the guard above returned for every other value of type.
      await dispatchReactionNotification(data, type!);
    } else {
      await dispatchCommentNotification(data, type!);
    }

    debugPrint('Push message processed successfully');
    if (background) {
      await DebugNotifier.instance.notifyBackgroundTaskCompleted();
    }
  } catch (e, st) {
    debugPrint('Error handling push message: $e');
    debugPrint(st.toString());
    if (background) {
      await DebugNotifier.instance.notifyBackgroundTaskFailed('$e');
    }
  }
}
