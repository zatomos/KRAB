import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/feed_events.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/instance/instance_bootstrap.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/services/upload_outbox.dart';

/// Everything here can run in a background isolate, keep it free of UI imports.

/// Handles an FCM message delivered while the app is backgrounded or killed.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await bootstrapBackgroundIsolate();

  final data = message.data.map((k, v) => MapEntry(k, '$v'));

  try {
    // Bring up the default FirebaseApp for the first instance holding an FCM
    // config rather than for whichever instance this message names.
    final instance =
        InstanceRegistry.instance.all.where((i) => i.config.hasFcm).firstOrNull;
    if (instance != null && Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: instance.config.fcmApiKey,
          appId: instance.config.fcmAppId,
          messagingSenderId: instance.config.fcmSenderId,
          projectId: instance.config.fcmProjectId,
        ),
      );
    }
  } catch (e) {
    debugPrint('Background Firebase init failed: $e');
  }

  await handlePushPayload(data, background: true, senderId: message.senderId);
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

      final instances = InstanceRegistry.instance.all;
      if (instances.isEmpty) {
        debugPrint('WorkManager: no instance configured, nothing to do');
        return Future.value(false);
      }

      var anyUsable = false;
      for (final instance in instances) {
        if (await instance.auth.getValidToken() != null) anyUsable = true;
      }
      if (!anyUsable) {
        await refreshWidgetAuthState();

        // Queued photos keep until the user reopens the app and
        // re-authenticates.
        debugPrint('WorkManager: no valid session anywhere, skipping');
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
  String? senderId,
}) async {
  final type = data['type'];
  debugPrint('Push: handling type="$type" (background=$background)');

  if (type != 'new_image' &&
      type != 'new_comment' &&
      type != 'group_comment' &&
      type != 'comment_reply' &&
      type != 'new_reaction' &&
      type != 'group_reaction' &&
      type != 'image_deleted' &&
      type != 'image_description_changed') {
    debugPrint('Push message type "$type" not handled, skipping');
    return;
  }

  try {
    if (background) {
      await bootstrapBackgroundIsolate();
      await DebugNotifier.instance.notifyBackgroundTaskStarted();
    }

    // Which server sent this. Everything below reads and writes through it, so
    // a message can never be answered against the wrong instance.
    final instance = instanceForPayload(data, senderId: senderId);
    if (instance == null) {
      debugPrint('Push: no instance for this message, dropping');
      if (background) {
        await DebugNotifier.instance
            .notifySupabaseInitFailed('Background: no instance configured');
      }
      return;
    }

    if (background && await instance.auth.getValidToken() == null) {
      await DebugNotifier.instance.notifyBackgroundTaskFailed(
          'Background session unavailable, reopen the app to re-authenticate');
      return;
    }

    if (type == 'new_image') {
      await dispatchImageNotification(instance, data);
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
      // The share id names the photo's other copies, whose notification may be
      // the one on screen. Absent when the image is gone from the server
      // entirely, which is what the copies recorded on the notification cover.
      await cancelImageNotification(
        instance,
        data['image_id'] ?? '',
        shareId: data['share_id'],
      );
      await updateHomeWidget();
    } else if (type == 'image_description_changed') {
      await updateImageNotificationDescription(
        instance,
        data['image_id'] ?? '',
        shareId: data['share_id'],
      );
      await updateHomeWidget(updatedDescriptions: true);
    } else if (type == 'new_reaction' || type == 'group_reaction') {
      // Non-null: the guard above returned for every other value of type.
      await dispatchReactionNotification(instance, data, type!);
    } else {
      await dispatchCommentNotification(instance, data, type!);
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
