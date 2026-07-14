import 'package:cached_network_image/cached_network_image.dart';

/// Drops an avatar from the image cache by its stable [cacheKey] (the object's
/// id). Avatars are cached by id rather than their rotating signed URL, so this
/// must be called whenever the underlying image changes to fetch the new one.
Future<void> evictAvatar(String cacheKey) async {
  // Disk: the cached file is keyed by cacheKey.
  await CachedNetworkImage.evictFromCache('', cacheKey: cacheKey);
  // Memory: the ImageCache entry is keyed by (cacheKey ?? url); evictFromCache
  // only evicts memory by url, so evict by the cacheKey explicitly here.
  await CachedNetworkImageProvider('', cacheKey: cacheKey).evict();
}
