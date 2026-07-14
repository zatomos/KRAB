import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart' as img;
import 'package:krab/l10n/app_localizations.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/user_preferences.dart';
import 'package:path_provider/path_provider.dart';

/// Delete cached big-picture notification images older than [maxAge] so they
/// don't accumulate unbounded in the temporary directory.
Future<void> _pruneOldNotifImages(Directory dir,
    {Duration maxAge = const Duration(days: 2)}) async {
  try {
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('notif_img_') || !name.endsWith('.jpg')) continue;
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {
        // Racing with another isolate deleting the same file; ignore.
      }
    }
  } catch (e) {
    debugPrint('notif: prune failed: $e');
  }
}

AppLocalizations _l10n() {
  final locale = ui.PlatformDispatcher.instance.locale;
  try {
    return lookupAppLocalizations(locale);
  } catch (_) {
    return lookupAppLocalizations(const Locale('en'));
  }
}

final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();

/// A stable, non-negative notification id derived from a string.
int _notificationId(String source) {
  var hash = 0x811c9dc5; // FNV-1a 32-bit offset basis
  for (final unit in source.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}

/// Stable notification id for one delivery of an image.
int imageNotificationId(String imageId, {String batchKey = ''}) =>
    _notificationId(batchKey.isEmpty ? imageId : '$imageId|$batchKey');

/// Stable notification id for one comment.
int commentNotificationId(String commentId) =>
    _notificationId('comment|$commentId');

/// Stable notification id for one user's reaction to one image. A user changing
/// their emoji replaces their notification rather than adding another.
int reactionNotificationId(String imageId, String reactorId) =>
    _notificationId('reaction|$imageId|$reactorId');

/// Fallback id for an event we can't identify.
int _unidentifiedNotificationId() =>
    DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF;

/// Identifies one delivery of a photo: the set of groups it reached together.
String imageBatchKey(Iterable<String> groupIds) =>
    (groupIds.toList()..sort()).join(',');

/// Dismiss a deleted image's notifications and drop its cached big-picture file.
Future<void> cancelImageNotification(String imageId) async {
  await _ensureFlnpInitialized();

  // A notification shown by an older build carries the bare-image-id form.
  await _flnp.cancel(id: imageNotificationId(imageId));

  try {
    for (final notification in await _flnp.getActiveNotifications()) {
      final id = notification.id;
      final payload = notification.payload;
      if (id == null || payload == null || payload.isEmpty) continue;
      try {
        final data = jsonDecode(payload) as Map<String, dynamic>;
        if (data['image_id'] == imageId) {
          await _flnp.cancel(id: id);
        }
      } catch (_) {
        // Not a payload we wrote; leave it alone.
      }
    }
  } catch (e) {
    debugPrint('notif: could not scan active notifications: $e');
  }

  try {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/notif_img_$imageId.jpg');
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

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

Future<bool> requestNotificationPermission() async {
  await _ensureFlnpInitialized();
  final android = _flnp.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (android == null) return true;

  final granted = await android.requestNotificationsPermission() ?? false;
  debugPrint('Notify: POST_NOTIFICATIONS granted=$granted');
  return granted;
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
  if (await UserPreferences.isGroupMuted(groupId)) return;
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
    commentId: commentId,
    commenterUsername: commenterUsername,
    commentText: commentText,
    imageId: imageId,
    type: type,
    commenterAvatarBytes: results[0].data,
    uploaderUsername: uploaderUsername,
    imageBytes: results[1].data,
  );
}

Future<void> dispatchReactionNotification(Map<String, dynamic> data,
    [String type = 'new_reaction']) async {
  final imageId = data['image_id'] ?? '';
  final reactorId = data['reactor_id'] ?? '';
  final emoji = data['emoji'] ?? '';

  if (imageId.isEmpty) return;

  final ctx = await getReactionNotificationContext(imageId, reactorId);
  if (!ctx.success || ctx.data == null) return;
  final d = ctx.data!;

  var reactorUsername = (d['reactor_username'] as String?) ?? '';
  if (reactorUsername.isEmpty) reactorUsername = 'Someone';

  final uploaderUsername =
      type == 'group_reaction' ? d['uploader_username'] as String? : null;

  final results = await Future.wait([
    reactorId.isNotEmpty
        ? getProfilePictureBytes(reactorId)
        : Future.value(SupabaseResponse<Uint8List>(success: false)),
    getImage(imageId, lowRes: true),
  ]);

  await initCommentNotifications();
  await showReactionNotification(
    reactorUsername: reactorUsername,
    reactorId: reactorId,
    emoji: emoji,
    imageId: imageId,
    uploaderUsername: uploaderUsername,
    reactorAvatarBytes: results[0].data,
    imageBytes: results[1].data,
  );
}

Future<void> dispatchImageNotification(Map<String, dynamic> data) async {
  final groupId = data['group_id'] ?? '';
  final imageId = data['image_id'] ?? '';

  if (groupId.isEmpty || imageId.isEmpty) {
    debugPrint('Notify: missing group_id/image_id, dropping');
    return;
  }

  final ctx = await getImageNotificationContext(imageId);
  if (!ctx.success || ctx.data == null) {
    debugPrint('Notify: no context for image $imageId (${ctx.error}), dropping');
    return;
  }

  // Every group the image is in that the user can see.
  final rawGroups = (ctx.data!['groups'] as List?) ?? const [];
  final groups = rawGroups
      .whereType<Map>()
      .map((g) => (
            id: (g['id'] as String?) ?? '',
            name: (g['name'] as String?) ?? '',
          ))
      .where((g) => g.id.isNotEmpty && g.name.isNotEmpty)
      .toList();
  if (groups.isEmpty) {
    debugPrint('Notify: image $imageId is in no group you can see, dropping');
    return;
  }

  // Narrow those to the groups this send actually delivered the photo to. An
  // image shared to several groups at once yields a single notification naming
  // all of them; an old image added to one group later names only that group,
  // rather than announcing it as if it had just landed everywhere.
  final batch = ((data['group_ids'] as String?) ?? '')
      .split(',')
      .where((s) => s.isNotEmpty)
      .toSet();
  var delivered =
      batch.isEmpty ? groups : groups.where((g) => batch.contains(g.id)).toList();
  if (delivered.isEmpty) delivered = groups;

  // Drop muted groups; only suppress the notification if every group is muted.
  final unmuted = <({String id, String name})>[];
  for (final g in delivered) {
    if (!await UserPreferences.isGroupMuted(g.id)) unmuted.add(g);
  }
  if (unmuted.isEmpty) {
    debugPrint('Notify: every group for image $imageId is muted, dropping');
    return;
  }

  // Use the triggering group for the notification channel when it survived the
  // mute filter, otherwise the first visible group. The subtext lists them all.
  final channel =
      unmuted.firstWhere((g) => g.id == groupId, orElse: () => unmuted.first);
  final groupsDisplay = unmuted.map((g) => g.name).join(', ');

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
    groupId: channel.id,
    groupName: channel.name,
    groupsDisplay: groupsDisplay,
    batchKey: imageBatchKey(delivered.map((g) => g.id)),
    // For a photo delivered to several groups at once, the tap goes to
    // the cross-group feed
    tapGroupId: unmuted.length == 1 ? channel.id : null,
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
  String? groupsDisplay,

  /// The group a tap should open. Null when the photo reached the user through
  /// more than one group, in which case the tap opens the cross-group feed.
  String? tapGroupId,
  String batchKey = '',
  String imageDescription = '',
  Uint8List? senderAvatarBytes,
  Uint8List? imageBytes,
}) async {
  await _ensureFlnpInitialized();
  await _createFlnpChannel(groupId, groupName);

  // Shown on the notification itself; lists every group the image was sent to.
  final subText = (groupsDisplay != null && groupsDisplay.isNotEmpty)
      ? groupsDisplay
      : groupName;

  final compositeBytes = _buildImageLargeIcon(imageBytes, senderAvatarBytes);

  final pfpCircle = _circleImage(senderAvatarBytes, 192);
  final pfpBytes =
      pfpCircle != null ? Uint8List.fromList(img.encodePng(pfpCircle)) : null;

  String? bigPicturePath;
  if (imageBytes != null) {
    try {
      final dir = await getTemporaryDirectory();
      // These big-picture files are only needed while the notification is on
      // screen; old ones would otherwise pile up in the cache forever, so prune
      // stale ones whenever a new image notification arrives.
      await _pruneOldNotifImages(dir);
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
    id: imageNotificationId(imageId, batchKey: batchKey),
    title: senderUsername,
    body: _l10n().new_image_notification,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        groupId,
        groupName,
        icon: '@drawable/ic_stat_krab_logo',
        subText: subText,
        importance: Importance.high,
        priority: Priority.high,
        largeIcon: compositeBytes != null
            ? ByteArrayAndroidBitmap(compositeBytes)
            : (pfpBytes != null ? ByteArrayAndroidBitmap(pfpBytes) : null),
        styleInformation: styleInformation,
      ),
    ),
    payload: jsonEncode({
      'type': 'new_image',
      'image_id': imageId,
      'group_id': tapGroupId ?? '',
    }),
  );
}

Future<void> showCommentNotification({
  required String groupId,
  required String groupName,
  required String commenterUsername,
  required String commentText,
  required String imageId,
  required String type,
  String commentId = '',
  Uint8List? commenterAvatarBytes,
  String? uploaderUsername,
  Uint8List? imageBytes,
}) async {
  await _ensureFlnpInitialized();
  await _createFlnpChannel(groupId, groupName);

  final compositeBytes = _buildImageLargeIcon(imageBytes, commenterAvatarBytes);

  await _flnp.show(
    id: commentId.isEmpty
        ? _unidentifiedNotificationId()
        : commentNotificationId(commentId),
    title: commenterUsername,
    body: type == 'comment_reply'
        ? _l10n().new_reply_notification
        : (uploaderUsername != null && uploaderUsername.isNotEmpty)
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


Future<void> showReactionNotification({
  required String reactorUsername,
  required String emoji,
  required String imageId,
  String reactorId = '',
  String? uploaderUsername,
  Uint8List? reactorAvatarBytes,
  Uint8List? imageBytes,
}) async {
  const channelId = 'reactions';
  final channelName = _l10n().reactions_title;
  await _ensureFlnpInitialized();
  await _createFlnpChannel(channelId, channelName);

  final compositeBytes = _buildImageLargeIcon(imageBytes, reactorAvatarBytes);

  await _flnp.show(
    id: reactorId.isEmpty
        ? _unidentifiedNotificationId()
        : reactionNotificationId(imageId, reactorId),
    title: reactorUsername,
    body: (uploaderUsername != null && uploaderUsername.isNotEmpty)
        ? _l10n().new_reaction_on_someone_notification(emoji, uploaderUsername)
        : _l10n().new_reaction_on_your_image_notification(emoji),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        icon: '@drawable/ic_stat_krab_logo',
        importance: Importance.high,
        priority: Priority.high,
        largeIcon: compositeBytes != null
            ? ByteArrayAndroidBitmap(compositeBytes)
            : null,
      ),
    ),
    payload: jsonEncode({'type': 'new_reaction', 'image_id': imageId}),
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
