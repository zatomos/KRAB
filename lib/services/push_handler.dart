import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/feed_events.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/supabase_bootstrap.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/services/upload_outbox.dart';
import 'package:krab/user_preferences.dart';

/// Everything here can run in a background isolate, keep it free of UI imports.

/// Handles an FCM message delivered while the app is backgrounded or killed.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await bootstrapBackgroundIsolate();

  try {
    if (UserPreferences.hasFcmConfig && Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: UserPreferences.fcmApiKey,
          appId: UserPreferences.fcmAppId,
          messagingSenderId: UserPreferences.fcmSenderId,
          projectId: UserPreferences.fcmProjectId,
        ),
      );
    }
  } catch (e) {
    debugPrint('Background Firebase init failed: $e');
  }

  await handlePushPayload(
    message.data.map((k, v) => MapEntry(k, '$v')),
    background: true,
  );
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
        await refreshWidgetAuthState();

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
