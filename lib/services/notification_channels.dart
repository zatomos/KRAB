import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart' as img;
import 'package:krab/l10n/app_localizations.dart';
import 'package:krab/services/supabase.dart';
import 'package:path_provider/path_provider.dart';

AppLocalizations _l10n() {
  final locale = ui.PlatformDispatcher.instance.locale;
  try {
    return lookupAppLocalizations(locale);
  } catch (_) {
    return lookupAppLocalizations(const Locale('en'));
  }
}

final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();

bool _flnpInitialized = false;

void Function(String payload)? _notificationTapHandler;

Future<void> _ensureFlnpInitialized() async {
  if (_flnpInitialized) return;
  await _flnp.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_krab_logo'),
    ),
    onDidReceiveNotificationResponse: (details) {
      if (details.payload != null) {
        _notificationTapHandler?.call(details.payload!);
      }
    },
  );
  _flnpInitialized = true;
}

Future<void> _createFlnpChannel(String channelId, String channelName) async {
  final plugin = _flnp.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await plugin?.createNotificationChannel(
    AndroidNotificationChannel(channelId, channelName,
        importance: Importance.high),
  );
}

Future<void> initCommentNotifications({
  void Function(String payload)? onTap,
}) async {
  if (onTap != null) _notificationTapHandler = onTap;
  await _ensureFlnpInitialized();
}

Future<String?> getLocalNotificationLaunchPayload() async {
  await _ensureFlnpInitialized();
  final details = await _flnp.getNotificationAppLaunchDetails();
  if (details == null || !details.didNotificationLaunchApp) return null;
  return details.notificationResponse?.payload;
}


img.Image? _circleImage(Uint8List? bytes, int size) {
  if (bytes == null) return null;
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final squared = img.copyResizeCropSquare(decoded, size: size);
    return img.copyCropCircle(squared.convert(numChannels: 4));
  } catch (e) {
    debugPrint('notif: _circleImage failed: $e');
    return null;
  }
}

Uint8List? _buildImageLargeIcon(Uint8List? imageBytes, Uint8List? pfpBytes,
    {int size = 192}) {
  if (imageBytes == null) return null;
  try {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) return null;

    final rgba =
        img.copyResizeCropSquare(decoded, size: size).convert(numChannels: 4);

    if (pfpBytes != null) {
      final pfpCircle = _circleImage(pfpBytes, size ~/ 2.2);
      if (pfpCircle != null) {
        img.compositeImage(
          rgba,
          pfpCircle,
          dstX: rgba.width - pfpCircle.width,
          dstY: rgba.height - pfpCircle.height,
        );
      }
    }

    return Uint8List.fromList(img.encodePng(rgba));
  } catch (e) {
    debugPrint('notif: _buildImageLargeIcon failed: $e');
    return null;
  }
}

Future<void> dispatchCommentNotification(
    Map<String, dynamic> data, String type) async {
  final commentId = data['comment_id'] ?? '';

  String groupId;
  String imageId;
  String commenterId;
  String groupName;
  String commenterUsername;
  String commentText;
  String? uploaderUsername;

  if (commentId.isNotEmpty) {
    final ctx = await getCommentNotificationContext(commentId);
    if (!ctx.success || ctx.data == null) return;
    final d = ctx.data!;
    groupId = (d['group_id'] as String?) ?? '';
    imageId = (d['image_id'] as String?) ?? '';
    commenterId = (d['commenter_id'] as String?) ?? '';
    groupName = (d['group_name'] as String?) ?? '';
    commenterUsername = (d['commenter_username'] as String?) ?? '';
    commentText = (d['comment_text'] as String?) ?? '';
    // Only group_comment renders the uploader's name in the body.
    uploaderUsername =
        type == 'group_comment' ? d['uploader_username'] as String? : null;
  } else {
    // Legacy plaintext payload
    groupId = data['group_id'] ?? '';
    imageId = data['image_id'] ?? '';
    commenterId = data['commenter_id'] ?? '';
    final groupResponse = await getGroupDetails(groupId);
    groupName = (groupResponse.success && groupResponse.data != null)
        ? groupResponse.data!.name
        : '';
    commenterUsername = (data['commenter_username'] as String?) ?? '';
    commentText = (data['comment_text'] as String?) ?? '';
    uploaderUsername = data['uploader_username'] as String?;
  }

  if (groupId.isEmpty || groupName.isEmpty) return;
  if (commenterUsername.isEmpty) commenterUsername = 'Someone';

  final results = await Future.wait([
    commenterId.isNotEmpty
        ? getProfilePictureBytes(commenterId)
        : Future.value(SupabaseResponse<Uint8List>(success: false)),
    imageId.isNotEmpty
        ? getImage(imageId, lowRes: true)
        : Future.value(SupabaseResponse<Uint8List>(success: false)),
  ]);

  await initCommentNotifications();
  await showCommentNotification(
    groupId: groupId,
    groupName: groupName,
    commenterUsername: commenterUsername,
    commentText: commentText,
    imageId: imageId,
    type: type,
    commenterAvatarBytes: results[0].data,
    uploaderUsername: uploaderUsername,
    imageBytes: results[1].data,
  );
}

Future<void> dispatchImageNotification(Map<String, dynamic> data) async {
  final groupId = data['group_id'] ?? '';
  final imageId = data['image_id'] ?? '';

  if (groupId.isEmpty || imageId.isEmpty) return;

  final ctx = await getImageNotificationContext(imageId, groupId);
  if (!ctx.success || ctx.data == null) return;

  final groupName = (ctx.data!['group_name'] as String?) ?? '';
  if (groupName.isEmpty) return;

  final senderId = (ctx.data!['sender_id'] as String?) ?? '';
  var senderUsername = (ctx.data!['sender_username'] as String?) ?? '';
  if (senderUsername.isEmpty) senderUsername = 'Someone';
  final imageDescription = (ctx.data!['description'] as String?) ?? '';

  final results = await Future.wait([
    senderId.isNotEmpty
        ? getProfilePictureBytes(senderId)
        : Future.value(SupabaseResponse<Uint8List>(success: false)),
    getImage(imageId, lowRes: true),
  ]);

  await initCommentNotifications();
  await showImageNotification(
    groupId: groupId,
    groupName: groupName,
    senderUsername: senderUsername,
    imageId: imageId,
    imageDescription: imageDescription,
    senderAvatarBytes: results[0].data,
    imageBytes: results[1].data,
  );
}

Future<void> showImageNotification({
  required String groupId,
  required String groupName,
  required String senderUsername,
  required String imageId,
  String imageDescription = '',
  Uint8List? senderAvatarBytes,
  Uint8List? imageBytes,
}) async {
  await _ensureFlnpInitialized();
  await _createFlnpChannel(groupId, groupName);

  final compositeBytes = _buildImageLargeIcon(imageBytes, senderAvatarBytes);

  final pfpCircle = _circleImage(senderAvatarBytes, 192);
  final pfpBytes =
      pfpCircle != null ? Uint8List.fromList(img.encodePng(pfpCircle)) : null;

  String? bigPicturePath;
  if (imageBytes != null) {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/notif_img_$imageId.jpg');
      await f.writeAsBytes(imageBytes);
      bigPicturePath = f.path;
    } catch (e) {
      debugPrint('notif: failed to cache image: $e');
    }
  }

  final styleInformation = bigPicturePath != null
      ? BigPictureStyleInformation(FilePathAndroidBitmap(bigPicturePath),
          largeIcon: pfpBytes != null ? ByteArrayAndroidBitmap(pfpBytes) : null,
          contentTitle: senderUsername,
          summaryText: imageDescription.isNotEmpty
              ? imageDescription
              : _l10n().no_description)
      : null;

  await _flnp.show(
    id: DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF,
    title: senderUsername,
    body: _l10n().new_image_notification,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        groupId,
        groupName,
        icon: '@drawable/ic_stat_krab_logo',
        subText: groupName,
        importance: Importance.high,
        priority: Priority.high,
        largeIcon: compositeBytes != null
            ? ByteArrayAndroidBitmap(compositeBytes)
            : (pfpBytes != null ? ByteArrayAndroidBitmap(pfpBytes) : null),
        styleInformation: styleInformation,
      ),
    ),
    payload: jsonEncode(
        {'type': 'new_image', 'image_id': imageId, 'group_id': groupId}),
  );
}

Future<void> showCommentNotification({
  required String groupId,
  required String groupName,
  required String commenterUsername,
  required String commentText,
  required String imageId,
  required String type,
  Uint8List? commenterAvatarBytes,
  String? uploaderUsername,
  Uint8List? imageBytes,
}) async {
  await _ensureFlnpInitialized();
  await _createFlnpChannel(groupId, groupName);

  final compositeBytes = _buildImageLargeIcon(imageBytes, commenterAvatarBytes);

  await _flnp.show(
    id: DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF,
    title: commenterUsername,
    body: (uploaderUsername != null && uploaderUsername.isNotEmpty)
        ? _l10n().new_comment_on_someone_notification(uploaderUsername)
        : _l10n().new_comment_on_your_image_notification,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        groupId,
        groupName,
        icon: '@drawable/ic_stat_krab_logo',
        subText: groupName,
        importance: Importance.high,
        priority: Priority.high,
        largeIcon: compositeBytes != null
            ? ByteArrayAndroidBitmap(compositeBytes)
            : null,
        styleInformation: BigTextStyleInformation(commentText),
      ),
    ),
    payload:
        jsonEncode({'type': type, 'image_id': imageId, 'group_id': groupId}),
  );
}

/// Notify the user that a newer app version is available
Future<void> showUpdateNotification(String version) async {
  const channelId = 'app_updates';
  const channelName = 'App updates';
  await _ensureFlnpInitialized();
  await _createFlnpChannel(channelId, channelName);

  await _flnp.show(
    id: 0x4B524142, // stable id ("KRAB") so a newer notification replaces it
    title: _l10n().update_available,
    body: _l10n().version(version),
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        icon: '@drawable/ic_stat_krab_logo',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: jsonEncode({'type': 'app_update'}),
  );
}
