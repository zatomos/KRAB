import 'package:flutter/foundation.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/models/image_details.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/api/supabase.dart';

/// The calls [FeedImageCache] makes to fill itself. Subclass to fetch something
/// other than the live backend; the default is the backend.
class ImageFetchers {
  const ImageFetchers();

  Future<SupabaseResponse<Uint8List>> image(String imageId,
          {bool lowRes = false}) =>
      getImage(imageId, lowRes: lowRes);

  Future<SupabaseResponse<ImageDetails>> details(String imageId) =>
      getImageDetails(imageId);

  Future<SupabaseResponse<krab_user.User>> user(String userId) =>
      getUserDetails(userId);

  /// An image's comment count: within one group, or across every group the user
  /// shares it with when groupId is null.
  Future<SupabaseResponse<int>> commentCount(String imageId, String? groupId) =>
      groupId != null
          ? getCommentCount(imageId, groupId)
          : getImageCommentCount(imageId);

  Future<SupabaseResponse<List<dynamic>>> reactions(String imageId) =>
      getImageReactions(imageId);
}

/// Everything one gallery holds in memory for the images it is showing: the
/// bytes, the uploader, and the comment and reaction tallies.
///
/// Owned by the feed and shared with the viewer it opens, so swiping between
/// photos and closing back to the grid never re-downloads what is already here.
///
/// Full-resolution photos get a much smaller window than thumbnails: KRAB
/// uploads them uncompressed, so a handful of them is already tens of megabytes,
/// while a thumbnail is a rounding error.
class FeedImageCache {
  /// The group whose gallery this is, or null in the cross-group feed, which
  /// decides whether a comment count is per-group or across every shared group.
  final String? groupId;

  final ImageFetchers _fetch;

  FeedImageCache({this.groupId, ImageFetchers fetchers = const ImageFetchers()})
      : _fetch = fetchers;

  static const int maxImages = 60;
  static const int maxFullResImages = 5;

  final Map<String, Uint8List> _lowRes = {};
  final Map<String, Uint8List> _fullRes = {};
  final Map<String, Future<Uint8List?>> _fullResFutures = {};
  final Map<String, Future<ImageData>> _imageDataFutures = {};
  final Map<String, krab_user.User> _users = {};
  final Map<String, int> _commentCounts = {};
  final Map<String, int> _reactionCounts = {};

  final List<String> _lru = [];
  final List<String> _fullResLru = [];

  /// The uploader of an image, once its details have loaded.
  krab_user.User? user(String userId) => _users[userId];

  int commentCount(String imageId) => _commentCounts[imageId] ?? 0;

  int reactionCount(String imageId) => _reactionCounts[imageId] ?? 0;

  void addToCommentCount(String imageId, int delta) {
    _commentCounts[imageId] = commentCount(imageId) + delta;
  }

  /// An image's thumbnail, details and tallies, fetched once and memoized so
  /// every rebuild hands the same future to its FutureBuilder.
  Future<ImageData> imageData(String imageId) {
    // Touch before reading, so a just-requested image is never the one evicted.
    _touch(imageId);
    final cached = _imageDataFutures[imageId];
    if (cached != null) return cached;
    final future = _fetchImageData(imageId);
    _imageDataFutures[imageId] = future;
    return future;
  }

  /// Start (or join) the full-resolution download for an image.
  Future<Uint8List?> fullResBytes(String imageId) {
    _touchFullRes(imageId);
    final cached = _fullResFutures[imageId];
    if (cached != null) return cached;
    final future = bytes(imageId, lowRes: false);
    _fullResFutures[imageId] = future;
    return future;
  }

  /// An image's bytes at one resolution, from memory when they're already here.
  Future<Uint8List?> bytes(String imageId, {bool lowRes = true}) async {
    final cache = lowRes ? _lowRes : _fullRes;
    final held = cache[imageId];
    if (held != null) return held;

    final response = await _fetch.image(imageId, lowRes: lowRes);
    final data = response.data;
    if (!response.success || data == null) return null;

    cache[imageId] = data;
    if (!lowRes) _touchFullRes(imageId);
    return data;
  }

  /// The best bytes already loaded for an image, falling back to the thumbnail.
  Future<Uint8List?> bestBytes(String imageId) async =>
      await bytes(imageId, lowRes: false) ?? await bytes(imageId);

  Future<ImageData> _fetchImageData(String imageId) async {
    final bytesFuture = bytes(imageId, lowRes: true);
    final detailsFuture = _fetch.details(imageId);
    final countFuture = _commentCounts.containsKey(imageId)
        ? null
        : _fetch.commentCount(imageId, groupId);
    final reactionsFuture =
        _reactionCounts.containsKey(imageId) ? null : _fetch.reactions(imageId);

    final imageBytes = await bytesFuture;
    if (imageBytes == null) throw Exception("Error downloading low-res image");

    final detailsResponse = await detailsFuture;
    final details = detailsResponse.data;
    if (!detailsResponse.success || details == null) {
      throw Exception("Error fetching image details: ${detailsResponse.error}");
    }

    final uploaderId = details.uploadedBy;
    if (!_users.containsKey(uploaderId)) {
      final response = await _fetch.user(uploaderId);
      _users[uploaderId] =
          response.data ?? krab_user.User(id: uploaderId, username: "");
    }

    if (countFuture != null) {
      final response = await countFuture;
      _commentCounts[imageId] = response.data ?? 0;
    }

    if (reactionsFuture != null) {
      final response = await reactionsFuture;
      _reactionCounts[imageId] = response.data?.fold<int>(
              0, (sum, e) => sum + ((e['count'] as num?)?.toInt() ?? 0)) ??
          0;
    }

    return ImageData(
      imageBytes: imageBytes,
      uploadedBy: uploaderId,
      createdAt: details.createdAt,
      description: details.description,
    );
  }

  /// Mark an image most-recently used, evicting whatever falls out the far end.
  void _touch(String imageId) {
    _lru
      ..remove(imageId)
      ..add(imageId);
    while (_lru.length > maxImages) {
      drop(_lru.removeAt(0));
    }
  }

  /// The same, over the much smaller full-resolution window.
  void _touchFullRes(String imageId) {
    _fullResLru
      ..remove(imageId)
      ..add(imageId);
    while (_fullResLru.length > maxFullResImages) {
      final evicted = _fullResLru.removeAt(0);
      _fullRes.remove(evicted);
      _fullResFutures.remove(evicted);
    }
  }

  /// Forget the bytes held for one image. The tallies are kept: they are a few
  /// bytes each, and re-fetching them would cost a round trip.
  void drop(String imageId) {
    _lowRes.remove(imageId);
    _fullRes.remove(imageId);
    _fullResFutures.remove(imageId);
    _imageDataFutures.remove(imageId);
    _lru.remove(imageId);
    _fullResLru.remove(imageId);
  }

  /// Forget an image entirely, once it has been deleted.
  void evict(String imageId) {
    drop(imageId);
    _commentCounts.remove(imageId);
    _reactionCounts.remove(imageId);
  }

  void clear() {
    _lowRes.clear();
    _fullRes.clear();
    _fullResFutures.clear();
    _imageDataFutures.clear();
    _users.clear();
    _commentCounts.clear();
    _reactionCounts.clear();
    _lru.clear();
    _fullResLru.clear();
  }
}
