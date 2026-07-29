import 'package:flutter/foundation.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/models/image_details.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/shared_image_api.dart';

/// An image's metadata together with the copy it was read from.
typedef DetailsFromCopy = ({ImageDetails details, ImageRef copy});

/// The calls FeedImageCache makes to fill itself.
abstract class ImageFetchers {
  Future<Uint8List?> bytes(SharedImage image, {required bool lowRes});

  /// Metadata, and which copy provided it.
  Future<DetailsFromCopy?> details(SharedImage image, {String? preferInstanceId});

  /// The uploader, as named by the instance the copy lives on.
  Future<krab_user.User?> uploader(ImageRef copy, String userId);

  /// Comments across every copy: within one group, or across every group the
  /// user shares the image with when groupId is null.
  Future<int> commentCount(SharedImage image, String? groupId);

  /// Reactions across every copy.
  Future<int> reactionCount(SharedImage image);
}

/// Reads an image from whichever of its copies answers.
/// An image that lives on two servers is still viewable when one of them is
/// down.
class RegistryImageFetchers implements ImageFetchers {
  const RegistryImageFetchers();

  @override
  Future<Uint8List?> bytes(SharedImage image, {required bool lowRes}) async {
    for (final copy in image.copies) {
      final instance = InstanceRegistry.instance.byId(copy.instanceId);
      if (instance == null) continue;
      final response = await instance.api.getImage(copy.id, lowRes: lowRes);
      if (response.success && response.data != null) return response.data;
      debugPrint('Feed: ${copy.instanceId} could not serve ${copy.id} '
          '(${response.error})');
    }
    return null;
  }

  @override
  Future<DetailsFromCopy?> details(SharedImage image,
      {String? preferInstanceId}) async {
    // The preferred copy first, then the rest in registration order.
    final ordered = <ImageRef>[
      ...image.copies.where((c) => c.instanceId == preferInstanceId),
      ...image.copies.where((c) => c.instanceId != preferInstanceId),
    ];

    for (final copy in ordered) {
      final instance = InstanceRegistry.instance.byId(copy.instanceId);
      if (instance == null) continue;
      final response = await instance.api.getImageDetails(copy.id);
      if (response.success && response.data != null) {
        return (details: response.data!, copy: copy);
      }
    }
    return null;
  }

  @override
  Future<krab_user.User?> uploader(ImageRef copy, String userId) async {
    final instance = InstanceRegistry.instance.byId(copy.instanceId);
    if (instance == null) return null;
    final response = await instance.api.getUserDetails(userId);
    return response.data;
  }

  @override
  Future<int> commentCount(SharedImage image, String? groupId) async {
    if (groupId == null) return SharedImageApi(image).commentCount();

    for (final copy in image.copies) {
      final instance = InstanceRegistry.instance.byId(copy.instanceId);
      if (instance == null) continue;
      final response = await instance.api.getCommentCount(copy.id, groupId);
      if (response.success) return response.data ?? 0;
    }
    return 0;
  }

  @override
  Future<int> reactionCount(SharedImage image) async {
    final reactions = await SharedImageApi(image).reactions();
    if (reactions == null) return 0;
    return reactions.tally.fold<int>(0, (sum, r) => sum + r.count);
  }
}

/// Everything one gallery holds in memory for the images it is showing: the
/// bytes, the uploader, and the comment and reaction tallies.
///
/// Owned by the feed and shared with the viewer it opens, so swiping between
/// images and closing back to the grid never re-downloads what is already here.
///
/// Keyed by SharedImage.identity, so an image sent to several instances is one
/// entry here exactly as it is one tile on screen.
///
/// Full-resolution images get a much smaller window than thumbnails: KRAB
/// uploads them uncompressed, so a handful of them is already tens of megabytes,
/// while a thumbnail is a rounding error.
class FeedImageCache {
  FeedImageCache({
    this.groupId,
    this.instanceId,
    ImageFetchers fetchers = const RegistryImageFetchers(),
  }) : _fetch = fetchers;

  /// The group whose gallery this is, or null in the cross-group feed, which
  /// decides whether a comment count is per-group or across every shared group.
  final String? groupId;

  final String? instanceId;
  final ImageFetchers _fetch;

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

  /// The uploader of an image, once its details have loaded. Keyed by the
  /// image's identity rather than the user id as the same person has
  /// a different account on each server.
  krab_user.User? user(SharedImage image) => _users[image.identity];

  int commentCount(SharedImage image) => _commentCounts[image.identity] ?? 0;

  int reactionCount(SharedImage image) => _reactionCounts[image.identity] ?? 0;

  void addToCommentCount(SharedImage image, int delta) {
    _commentCounts[image.identity] = commentCount(image) + delta;
  }

  /// An image's thumbnail, details and tallies, fetched once and memoized so
  /// every rebuild hands the same future to its FutureBuilder.
  Future<ImageData> imageData(SharedImage image) {
    // Touch before reading, so a just-requested image is never the one evicted.
    _touch(image.identity);
    final cached = _imageDataFutures[image.identity];
    if (cached != null) return cached;
    final future = _fetchImageData(image);
    _imageDataFutures[image.identity] = future;
    return future;
  }

  /// Start (or join) the full-resolution download for an image.
  Future<Uint8List?> fullResBytes(SharedImage image) {
    _touchFullRes(image.identity);
    final cached = _fullResFutures[image.identity];
    if (cached != null) return cached;
    final future = bytes(image, lowRes: false);
    _fullResFutures[image.identity] = future;
    return future;
  }

  /// An image's bytes at one resolution, from memory when they're already here.
  Future<Uint8List?> bytes(SharedImage image, {bool lowRes = true}) async {
    final cache = lowRes ? _lowRes : _fullRes;
    final held = cache[image.identity];
    if (held != null) return held;

    final data = await _fetch.bytes(image, lowRes: lowRes);
    if (data == null) return null;

    cache[image.identity] = data;
    if (!lowRes) _touchFullRes(image.identity);
    return data;
  }

  /// The best bytes already loaded for an image, falling back to the thumbnail.
  Future<Uint8List?> bestBytes(SharedImage image) async =>
      await bytes(image, lowRes: false) ?? await bytes(image);

  Future<ImageData> _fetchImageData(SharedImage image) async {
    final identity = image.identity;
    final bytesFuture = bytes(image, lowRes: true);
    final detailsFuture = _fetch.details(image, preferInstanceId: instanceId);
    final countFuture = _commentCounts.containsKey(identity)
        ? null
        : _fetch.commentCount(image, groupId);
    final reactionsFuture = _reactionCounts.containsKey(identity)
        ? null
        : _fetch.reactionCount(image);

    final imageBytes = await bytesFuture;
    if (imageBytes == null) throw Exception("Error downloading low-res image");

    final resolved = await detailsFuture;
    if (resolved == null) throw Exception("Error fetching image details");
    final details = resolved.details;

    final uploaderId = details.uploadedBy;
    if (!_users.containsKey(identity)) {
      final user = await _fetch.uploader(resolved.copy, uploaderId);
      _users[identity] = user ??
          krab_user.User(
            instanceId: resolved.copy.instanceId,
            id: uploaderId,
            username: "",
          );
    }

    if (countFuture != null) _commentCounts[identity] = await countFuture;
    if (reactionsFuture != null) {
      _reactionCounts[identity] = await reactionsFuture;
    }

    return ImageData(
      imageBytes: imageBytes,
      uploadedBy: uploaderId,
      uploaderInstanceId: resolved.copy.instanceId,
      createdAt: details.createdAt,
      description: details.description,
    );
  }

  /// Mark an image most-recently used, evicting whatever falls out the far end.
  void _touch(String identity) {
    _lru
      ..remove(identity)
      ..add(identity);
    while (_lru.length > maxImages) {
      _drop(_lru.removeAt(0));
    }
  }

  /// The same, over the much smaller full-resolution window.
  void _touchFullRes(String identity) {
    _fullResLru
      ..remove(identity)
      ..add(identity);
    while (_fullResLru.length > maxFullResImages) {
      final evicted = _fullResLru.removeAt(0);
      _fullRes.remove(evicted);
      _fullResFutures.remove(evicted);
    }
  }

  /// Forget the bytes held for one image. The tallies are kept: they are a few
  /// bytes each, and re-fetching them would cost a round trip.
  void drop(SharedImage image) => _drop(image.identity);

  void _drop(String identity) {
    _lowRes.remove(identity);
    _fullRes.remove(identity);
    _fullResFutures.remove(identity);
    _imageDataFutures.remove(identity);
    _lru.remove(identity);
    _fullResLru.remove(identity);
  }

  /// Forget an image entirely, once it has been deleted.
  void evict(SharedImage image) {
    _drop(image.identity);
    _commentCounts.remove(image.identity);
    _reactionCounts.remove(image.identity);
    _users.remove(image.identity);
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
