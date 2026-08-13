import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:krab/models/user.dart' as krab_user;

/// The cache key an avatar or group icon is stored under.
///
/// Scoped to the instance: ids are only unique within the server that issued
/// them, so two instances sharing a key would show each other's pictures.
String avatarCacheKey(String instanceId, String id) => '$instanceId/$id';

/// Drops an avatar from the image cache by its stable id. Avatars are cached by
/// id rather than their rotating signed URL, so this must be called whenever
/// the underlying image changes to fetch the new one.
Future<void> evictAvatar(String instanceId, String id) async {
  final cacheKey = avatarCacheKey(instanceId, id);
  // Disk: the cached file is keyed by cacheKey.
  await CachedNetworkImage.evictFromCache('', cacheKey: cacheKey);
  // Memory: the ImageCache entry is keyed by (cacheKey ?? url); evictFromCache
  // only evicts memory by url, so evict by the cacheKey explicitly here.
  await CachedNetworkImageProvider('', cacheKey: cacheKey).evict();
}

/// Decodes a user's avatar into the in-memory image cache ahead of being shown.
Future<void> precacheAvatar(BuildContext context, krab_user.User? user) async {
  if (user == null || user.pfpUrl.isEmpty) return;
  await precacheImage(
    CachedNetworkImageProvider(
      user.pfpUrl,
      cacheKey: avatarCacheKey(user.instanceId, user.id),
    ),
    context,
    onError: (error, _) => debugPrint('⚠️ Failed to precache avatar: $error'),
  );
}
