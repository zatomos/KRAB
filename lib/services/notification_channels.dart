import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart' as img;
import 'package:krab/l10n/app_localizations.dart';
import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/instance/krab_instance.dart';
import 'package:krab/services/notification_ids.dart';
import 'package:krab/services/notification_records.dart';
import 'package:krab/services/notification_summaries.dart';
import 'package:krab/services/shown_image_notifications.dart';
import 'package:krab/user_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:krab/services/notification_ids.dart';

part 'notification_channels_images.dart';
part 'notification_channels_comments.dart';
part 'notification_channels_reactions.dart';
part 'notification_channels_bundles.dart';

final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();

const String _icon = '@drawable/ic_stat_krab_logo';

AppLocalizations _l10n() {
  final locale = ui.PlatformDispatcher.instance.locale;
  try {
    return lookupAppLocalizations(locale);
  } catch (_) {
    return lookupAppLocalizations(const Locale('en'));
  }
}

/// The channels KRAB posts on.
enum KrabChannel {
  images('krab_images', Importance.high),
  comments('krab_comments', Importance.high),
  reactions('krab_reactions', Importance.low),

  appUpdates('krab_app_updates', Importance.defaultImportance);

  const KrabChannel(this.id, this.importance);

  final String id;
  final Importance importance;

  ({String name, String description}) get text {
    final l10n = _l10n();
    return switch (this) {
      KrabChannel.images => (
          name: l10n.channel_images,
          description: l10n.channel_images_description
        ),
      KrabChannel.comments => (
          name: l10n.channel_comments,
          description: l10n.channel_comments_description
        ),
      KrabChannel.reactions => (
          name: l10n.channel_reactions,
          description: l10n.channel_reactions_description
        ),
      KrabChannel.appUpdates => (
          name: l10n.channel_app_updates,
          description: l10n.channel_app_updates_description
        ),
    };
  }
}

bool _flnpInitialized = false;

void Function(String payload)? _notificationTapHandler;

Future<void> _ensureFlnpInitialized() async {
  if (_flnpInitialized) return;
  await _flnp.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings(_icon),
    ),
    onDidReceiveNotificationResponse: (details) {
      if (details.payload != null) {
        _notificationTapHandler?.call(details.payload!);
      }
    },
  );
  _flnpInitialized = true;
}

bool _channelsCreated = false;

AndroidFlutterLocalNotificationsPlugin? get _android =>
    _flnp.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

/// Make sure every channel KRAB posts on exists
Future<void> _ensureChannels() async {
  await _ensureFlnpInitialized();
  if (_channelsCreated) return;

  final plugin = _android;
  if (plugin == null) {
    _channelsCreated = true;
    return;
  }

  for (final channel in KrabChannel.values) {
    final text = channel.text;
    await plugin.createNotificationChannel(
      AndroidNotificationChannel(
        channel.id,
        text.name,
        description: text.description,
        importance: channel.importance,
      ),
    );
  }
  _channelsCreated = true;
}

/// Whether a channel id belongs to a build that gave every group one.
/// TODO: remove
bool isLegacyNotificationChannel(String id) {
  if (id == 'reactions' || id == 'app_updates') return true;
  return RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(id);
}

const String _channelMigrationKey = 'krab_notification_channels_collapsed';

/// Remove the per-group channels an older build created.
///  TODO: remove
Future<void> pruneLegacyNotificationChannels() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  if (prefs.getBool(_channelMigrationKey) == true) return;

  await _ensureChannels();
  final plugin = _android;
  if (plugin == null) return;

  try {
    final channels = await plugin.getNotificationChannels() ?? const [];
    var deleted = 0;
    for (final channel in channels) {
      if (!isLegacyNotificationChannel(channel.id)) continue;
      await plugin.deleteNotificationChannel(channelId: channel.id);
      deleted++;
    }
    await prefs.setBool(_channelMigrationKey, true);
    debugPrint('notif: removed $deleted per-group channel(s)');
  } catch (e) {
    // Leave the flag unset so the next launch tries again.
    debugPrint('notif: could not prune the old channels: $e');
  }
}

/// Bring up notifications and, in the app, tidy up after older builds.
Future<void> initNotifications({
  void Function(String payload)? onTap,
}) async {
  if (onTap != null) _notificationTapHandler = onTap;
  await _ensureChannels();
  await pruneLegacyNotificationChannels();
}

Future<bool> requestNotificationPermission() async {
  await _ensureFlnpInitialized();
  final plugin = _android;
  if (plugin == null) return true;

  final granted = await plugin.requestNotificationsPermission() ?? false;
  debugPrint('Notify: POST_NOTIFICATIONS granted=$granted');
  return granted;
}

Future<String?> getLocalNotificationLaunchPayload() async {
  await _ensureFlnpInitialized();
  final details = await _flnp.getNotificationAppLaunchDetails();
  if (details == null || !details.didNotificationLaunchApp) return null;
  return details.notificationResponse?.payload;
}

/// Delete old cached notification images so they don't accumulate
/// in the temp directory.
Future<void> _pruneOldNotifImages(Directory dir,
    {Duration maxAge = const Duration(days: 2)}) async {
  try {
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final ours = (name.startsWith('notif_img_') && name.endsWith('.jpg')) ||
          (name.startsWith('notif_pfp_') && name.endsWith('.png'));
      if (!ours) continue;
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {
      }
    }
  } catch (e) {
    debugPrint('notif: prune failed: $e');
  }
}

/// The avatar and image thumbnail a notification illustrates itself with,
/// fetched together.
Future<({Uint8List? avatar, Uint8List? image})> _notificationMedia(
    KrabInstance instance, String userId, String imageId) async {
  const missing = SupabaseResponse<Uint8List>(success: false);
  final results = await Future.wait([
    userId.isNotEmpty
        ? instance.api.getProfilePictureBytes(userId)
        : Future.value(missing),
    imageId.isNotEmpty
        ? instance.api.getImage(imageId, lowRes: true)
        : Future.value(missing),
  ]);
  return (avatar: results[0].data, image: results[1].data);
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

Uint8List? _circlePng(Uint8List? bytes, {int size = 192}) {
  final circle = _circleImage(bytes, size);
  return circle != null ? Uint8List.fromList(img.encodePng(circle)) : null;
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

AndroidBitmap<Object>? _largeIcon(Uint8List? imageBytes, Uint8List? pfpBytes) {
  final composite = _buildImageLargeIcon(imageBytes, pfpBytes);
  if (composite != null) return ByteArrayAndroidBitmap(composite);
  final circle = _circlePng(pfpBytes);
  return circle != null ? ByteArrayAndroidBitmap(circle) : null;
}

int? _whenMillis(DateTime? at) => at?.millisecondsSinceEpoch;

DateTime? _eventTime(Object? raw) {
  final parsed = DateTime.tryParse(raw?.toString() ?? '');
  return parsed?.toLocal();
}

/// The ids the system is showing, or null when it cannot say.
Future<Set<int>?> _activeNotificationIds() async {
  try {
    final active = await _flnp.getActiveNotifications();
    return {
      for (final notification in active)
        if (notification.id != null) notification.id!
    };
  } catch (e) {
    debugPrint('notif: could not list the active notifications: $e');
    return null;
  }
}

/// Notify the user that a newer app version is available
Future<void> showUpdateNotification(String version) async {
  await _ensureChannels();

  await _flnp.show(
    id: 0x4B524142, // stable id ("KRAB") so a newer notification replaces it
    title: _l10n().update_available,
    body: _l10n().version(version),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        KrabChannel.appUpdates.id,
        KrabChannel.appUpdates.text.name,
        channelDescription: KrabChannel.appUpdates.text.description,
        icon: _icon,
        importance: KrabChannel.appUpdates.importance,
        priority: Priority.defaultPriority,
        category: AndroidNotificationCategory.recommendation,
      ),
    ),
    payload: jsonEncode({'type': 'app_update'}),
  );
}
