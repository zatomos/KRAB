part of 'krab_api.dart';

/// ------------------ IMAGE FUNCTIONS ------------------

/// Largest image the server will accept
const int maxImageUploadBytes = 15 * 1024 * 1024;

/// Longest description the server will store.
const int maxDescriptionLength = 199;

/// The bytes are already in storage under this name.
bool _isAlreadyUploaded(Object error) =>
    error is StorageException &&
    (error.statusCode == '409' || error.error == 'Duplicate');

/// Storage bucket holding one pre-generated thumbnail per image, keyed by the
/// bare image id. The client reads them, and falls back to the full image
/// when a thumbnail hasn't been generated.
const String _thumbnailsBucket = 'image-thumbnails';

/// Strip EXIF metadata, and shrink the image if this build asks for it.
Future<Uint8List> prepareImageForUpload(File imageFile) async =>
    stripImageMetadata(
      await imageFile.readAsBytes(),
      maxDimension: maxUploadDimension,
      quality: uploadJpegQuality,
    );

/// Whether the server refused `p_share_id`
bool _isUnknownShareIdArgument(Object error) {
  if (error is! PostgrestException) return false;
  if (error.code == '42883' || error.code == 'PGRST202') return true;
  final message = error.message.toLowerCase();
  return message.contains('p_share_id') ||
      message.contains('could not find the function');
}

extension KrabApiImages on KrabApi {
  /// Send an image to selected groups with an optional description.
  ///
  /// shareId is what lets every copy of an image be recognised as one image
  /// later.
  Future<SupabaseResponse<String>> sendImageToGroups(
    File imageFile,
    List<String> selectedGroups,
    String description, {
    String? resumeImageId,
    String? shareId,
    Uint8List? preparedBytes,
    Future<void> Function(String imageId)? onReserved,
    void Function()? onShareIdDropped,
  }) async {
    try {
      // Sending one image to several instances prepares the bytes once and
      // hands them to each, so a fan-out re-encodes the image once rather than
      // once per server.
      final imageBytes =
          preparedBytes ?? await prepareImageForUpload(imageFile);

      if (imageBytes.length > maxImageUploadBytes) {
        return SupabaseResponse(success: false, error: errorImageTooLarge);
      }

      var imageId = resumeImageId;

      if (imageId == null) {
        // Open the upload: checks the groups, and reserves the id to store under
        final opened = await _withRetry(() => _requestUpload(
            selectedGroups, description, shareId,
            onShareIdDropped: onShareIdDropped));

        if (opened['success'] == false) {
          return SupabaseResponse(
            success: false,
            error: opened['error']?.toString(),
          );
        }

        imageId = opened['image_id'] as String;
        await onReserved?.call(imageId);
      }

      // Landing the bytes is what sends the image.
      try {
        await _withRetry(() => _client.storage.from("images").uploadBinary(
              imageId!,
              imageBytes,
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            ));
      } catch (error) {
        // The image is already there: an earlier attempt landed and only its
        // reply went missing. The trigger ran with it, so the image is sent.
        if (!_isAlreadyUploaded(error)) rethrow;
        debugPrint("Image $imageId was already uploaded, treating as sent");
      }

      return SupabaseResponse(success: true, data: imageId);
    } catch (error) {
      return _failure(error, "sending image");
    }
  }

  /// Opens the upload, carrying the share id when there is one.
  Future<dynamic> _requestUpload(
      List<String> groupIds, String description, String? shareId,
      {void Function()? onShareIdDropped}) async {
    Future<dynamic> call({required bool withShareId}) =>
        _client.rpc("request_image_upload", params: {
          "p_group_ids": groupIds,
          "p_description": description,
          if (withShareId) "p_share_id": shareId,
        });

    if (shareId == null) return call(withShareId: false);

    try {
      return await call(withShareId: true);
    } catch (error) {
      if (!_isUnknownShareIdArgument(error)) rethrow;
      debugPrint('Instance $instanceId does not know share_id; '
          'sending without it');
      onShareIdDropped?.call();
      return call(withShareId: false);
    }
  }

  /// Delete an image the current user uploaded, from every group it was shared
  /// to.
  Future<SupabaseResponse<void>> deleteImage(String imageId) async {
    final result = await _rpc<void>("delete_image",
        params: {"image_id": imageId}, errorContext: "deleting image");
    if (!result.success) return result;

    await _imageCache.remove(imageId);
    return SupabaseResponse(success: true);
  }

  /// Update an image the current user uploaded. An empty description clears it.
  Future<SupabaseResponse<void>> updateImageDescription(
          String imageId, String description) =>
      _rpc<void>("update_image_description",
          params: {"p_image_id": imageId, "p_description": description},
          errorContext: "updating the image description");

  /// Remove the current user's image from the given groups only. If that leaves
  /// it in no groups it's deleted outright. Returns whether it was fully
  /// deleted.
  Future<SupabaseResponse<bool>> removeImageFromGroups(
      String imageId, List<String> groupIds) async {
    final result = await _rpc<bool>("remove_image_from_groups",
        params: {"p_image_id": imageId, "p_group_ids": groupIds},
        errorContext: "removing image from groups",
        parse: (r) => r is Map && r["fully_deleted"] == true);
    // Only drop the cached bytes once the image is actually gone everywhere.
    if (result.success && (result.data ?? false)) {
      await _imageCache.remove(imageId);
    }
    return result;
  }

  /// Add an already-uploaded image the current user owns to more groups. Groups
  /// the image is already in are skipped.
  /// Returns how many group links were actually added.
  Future<SupabaseResponse<int>> addImageToGroups(
          String imageId, List<String> groupIds) =>
      _rpc<int>("add_image_to_groups",
          params: {"p_image_id": imageId, "p_group_ids": groupIds},
          errorContext: "adding image to groups",
          parse: (r) => r is Map && r["added"] is int ? r["added"] as int : 0);

  /// Get images for a given group, paginated
  Future<SupabaseResponse<List<ImageRef>>> getGroupImages(
    String groupId, {
    int? limit,
    DateTime? beforeCreatedAt,
    String? beforeId,
  }) =>
      _rpc("get_group_images",
          params: {
            "p_group_id": groupId,
            if (limit != null) "p_limit": limit,
            if (beforeCreatedAt != null)
              "p_before_created_at": beforeCreatedAt.toIso8601String(),
            if (beforeId != null) "p_before_id": beforeId,
          },
          errorContext: "loading group images",
          parse: (r) => (r['images'] as List)
              .map((e) => _imageRef(e as Map<String, dynamic>))
              .toList());

  /// Get the N most recent images accessible to the user, deduplicated
  /// across groups.
  /// If groupIds is provided and non-empty, only images from those groups are
  /// returned; otherwise images from all accessible groups are included.
  Future<SupabaseResponse<List<ImageRef>>> getLatestImages(
    int count, {
    List<String>? groupIds,
    DateTime? beforeCreatedAt,
    String? beforeId,
  }) =>
      _rpc("get_latest_images",
          params: {
            "p_count": count,
            if (groupIds != null && groupIds.isNotEmpty)
              "p_group_ids": groupIds,
            if (beforeCreatedAt != null)
              "p_before_created_at": beforeCreatedAt.toIso8601String(),
            if (beforeId != null) "p_before_id": beforeId,
          },
          errorContext: "loading latest images",
          parse: (r) => (r['images'] as List)
              .map((e) => _imageRef(e as Map<String, dynamic>))
              .toList());

  /// Decode one listed image.
  ImageRef _imageRef(Map<String, dynamic> json) =>
      ImageRef.fromJson(json, instanceId: instanceId);

  /// Give an image that has none a share id, so it can be posted to a group on
  /// another server and still read as the same image.
  Future<SupabaseResponse<String>> assignShareId(
          String imageId, String shareId) =>
      _rpc<String>("assign_share_id",
          params: {"p_image_id": imageId, "p_share_id": shareId},
          errorContext: "assigning a share id",
          parse: (r) => (r['share_id'] ?? shareId).toString());

  /// The copies this instance holds of any of shareIds.
  Future<SupabaseResponse<List<ImageRef>>> findImagesByShareId(
      List<String> shareIds) async {
    if (shareIds.isEmpty) {
      return const SupabaseResponse(success: true, data: []);
    }
    try {
      final response = await _client
          .rpc('get_images_by_share_id', params: {'p_share_ids': shareIds});
      if (response is Map && response['success'] == false) {
        return SupabaseResponse(
            success: false, error: response['error']?.toString());
      }
      final images = (response['images'] as List?) ?? const [];
      return SupabaseResponse(
        success: true,
        data: images.map((e) => _imageRef(e as Map<String, dynamic>)).toList(),
      );
    } catch (error) {
      if (_isUnknownShareIdArgument(error)) {
        debugPrint('Instance $instanceId cannot look images up by share id');
        return const SupabaseResponse(success: true, data: []);
      }
      return _failure(error, 'looking up shared copies');
    }
  }

  /// Download an image from storage, backed by a persistent on-disk cache.
  Future<SupabaseResponse<Uint8List>> getImage(String imageId,
      {bool lowRes = false}) async {
    final cacheKey = '$imageId.${lowRes ? 'low' : 'full'}';

    final cached = await _imageCache.read(cacheKey);
    if (cached != null) {
      return SupabaseResponse(success: true, data: cached);
    }

    try {
      debugPrint("Downloading image $imageId with transform: "
          "${lowRes ? 'low' : 'full'}");

      Uint8List data;
      // Whether what we got back is what the key says it is.
      var isThumbnail = false;

      if (lowRes) {
        final thumbnail = await _downloadThumbnail(imageId);
        data = thumbnail.bytes;
        isThumbnail = thumbnail.isThumbnail;
      } else {
        // Fullres download
        data = await _client.storage.from('images').download(imageId);
      }

      if (data.isEmpty) {
        return SupabaseResponse(success: false, error: errorServer);
      }

      // Populate the disk cache for next time.
      unawaited(_imageCache.write(
          lowRes && !isThumbnail ? '$imageId.full' : cacheKey, data));

      return SupabaseResponse(success: true, data: data);
    } catch (error, stack) {
      debugPrint("Error downloading image $imageId: $error");
      debugPrint(stack.toString());
      return _failure(error, "downloading image $imageId");
    }
  }

  /// Fetch an image's thumbnail, falling back to the full image when one hasn't
  /// been generated yet. Reports which of the two it returned.
  Future<({Uint8List bytes, bool isThumbnail})> _downloadThumbnail(
      String imageId) async {
    try {
      final data =
          await _client.storage.from(_thumbnailsBucket).download(imageId);
      if (data.isNotEmpty) {
        debugPrint("Thumbnail $imageId served statically");
        return (bytes: data, isThumbnail: true);
      }
    } catch (_) {
      // No static thumbnail yet, fall back to the full image.
    }

    debugPrint("Thumbnail $imageId not generated yet, serving the full image");
    final full = await _client.storage.from('images').download(imageId);
    return (bytes: full, isThumbnail: false);
  }

  /// Download a profile picture from storage.
  Future<SupabaseResponse<Uint8List>> getProfilePictureBytes(
      String userId) async {
    try {
      final data =
          await _client.storage.from('profile-pictures').download(userId);
      if (data.isEmpty) {
        return SupabaseResponse(success: false, error: errorServer);
      }
      return SupabaseResponse(success: true, data: data);
    } catch (error) {
      return _failure(error, 'downloading the profile picture');
    }
  }

  /// Get detailed information about an image.
  Future<SupabaseResponse<ImageDetails>> getImageDetails(String imageId) async {
    try {
      final response =
          await _client.rpc("get_image_details", params: {"image_id": imageId});
      if (response == null || response.isEmpty) {
        return SupabaseResponse(success: false, error: errorServer);
      }
      return SupabaseResponse(
          success: true,
          data: ImageDetails.fromJson(response.first as Map<String, dynamic>));
    } catch (error) {
      return _failure(error, "fetching image details");
    }
  }
}
