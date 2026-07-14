part of 'supabase.dart';

/// ------------------ IMAGE FUNCTIONS ------------------

/// Largest photo the server will accept
const int maxImageUploadBytes = 15 * 1024 * 1024;

/// The bytes are already in storage under this name.
bool _isAlreadyUploaded(Object error) =>
    error is StorageException &&
    (error.statusCode == '409' || error.error == 'Duplicate');

/// Send an image to selected groups with an optional description.
Future<SupabaseResponse<String>> sendImageToGroups(
  File imageFile,
  List<String> selectedGroups,
  String description, {
  String? resumeImageId,
  Future<void> Function(String imageId)? onReserved,
}) async {
  try {
    // Strip EXIF metadata, and shrink the photo if this build asks for it
    final imageBytes = await stripImageMetadata(
      await imageFile.readAsBytes(),
      maxDimension: maxUploadDimension,
      quality: uploadJpegQuality,
    );

    if (imageBytes.length > maxImageUploadBytes) {
      return SupabaseResponse(success: false, error: errorPhotoTooLarge);
    }

    var imageId = resumeImageId;

    if (imageId == null) {
      // Open the upload: checks the groups, and reserves the id to store under
      final opened =
          await _withRetry(() => supabase.rpc("request_image_upload", params: {
                "p_group_ids": selectedGroups,
                "p_description": description,
              }));

      if (opened['success'] == false) {
        return SupabaseResponse(
          success: false,
          error: opened['error']?.toString(),
        );
      }

      imageId = opened['image_id'] as String;
      await onReserved?.call(imageId);
    }

    // Landing the bytes is what sends the photo.
    try {
      await _withRetry(() => supabase.storage.from("images").uploadBinary(
            imageId!,
            imageBytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          ));
    } catch (error) {
      // The photo is already there: an earlier attempt landed and only its reply
      // went missing. The trigger ran with it, so the photo is sent.
      if (!_isAlreadyUploaded(error)) rethrow;
      debugPrint("Image $imageId was already uploaded, treating as sent");
    }

    return SupabaseResponse(success: true, data: imageId);
  } catch (error) {
    return _failure(error, "sending image");
  }
}

/// Delete an image the current user uploaded, from every group it was shared to.
Future<SupabaseResponse<void>> deleteImage(String imageId) async {
  final result = await _rpc<void>("delete_image",
      params: {"image_id": imageId}, errorContext: "deleting image");
  if (!result.success) return result;

  await ImageDiskCache.instance.remove(imageId);
  return SupabaseResponse(success: true);
}

/// Remove the current user's image from the given groups only. If that leaves it
/// in no groups it's deleted outright. Returns whether it was fully deleted.
Future<SupabaseResponse<bool>> removeImageFromGroups(
    String imageId, List<String> groupIds) async {
  final result = await _rpc<bool>("remove_image_from_groups",
      params: {"p_image_id": imageId, "p_group_ids": groupIds},
      errorContext: "removing image from groups",
      parse: (r) => r is Map && r["fully_deleted"] == true);
  // Only drop the cached bytes once the image is actually gone everywhere.
  if (result.success && (result.data ?? false)) {
    await ImageDiskCache.instance.remove(imageId);
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

/// Storage bucket holding one pre-generated thumbnail per image, keyed by the
/// bare image id. The client reads them, and falls back to the full image
/// when a thumbnail hasn't been generated.
const String _thumbnailsBucket = 'image-thumbnails';

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
            .map((e) => ImageRef.fromJson(e as Map<String, dynamic>))
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
          if (groupIds != null && groupIds.isNotEmpty) "p_group_ids": groupIds,
          if (beforeCreatedAt != null)
            "p_before_created_at": beforeCreatedAt.toIso8601String(),
          if (beforeId != null) "p_before_id": beforeId,
        },
        errorContext: "loading latest images",
        parse: (r) => (r['images'] as List)
            .map((e) => ImageRef.fromJson(e as Map<String, dynamic>))
            .toList());

/// Download an image from storage, backed by a persistent on-disk cache.
Future<SupabaseResponse<Uint8List>> getImage(String imageId,
    {bool lowRes = false}) async {
  final cacheKey = '$imageId.${lowRes ? 'low' : 'full'}';

  final cached = await ImageDiskCache.instance.read(cacheKey);
  if (cached != null) {
    return SupabaseResponse(success: true, data: cached);
  }

  try {
    debugPrint(
        "Downloading image $imageId with transform: ${lowRes ? 'low' : 'full'}");

    Uint8List data;
    // Whether what we got back is what the key says it is.
    var isThumbnail = false;

    if (lowRes) {
      final thumbnail = await _downloadThumbnail(imageId);
      data = thumbnail.bytes;
      isThumbnail = thumbnail.isThumbnail;
    } else {
      // Fullres download
      data = await supabase.storage.from('images').download(imageId);
    }

    if (data.isEmpty) {
      return SupabaseResponse(success: false, error: errorServer);
    }

    // Populate the disk cache for next time.
    unawaited(ImageDiskCache.instance
        .write(lowRes && !isThumbnail ? '$imageId.full' : cacheKey, data));

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
        await supabase.storage.from(_thumbnailsBucket).download(imageId);
    if (data.isNotEmpty) {
      debugPrint("Thumbnail $imageId served statically");
      return (bytes: data, isThumbnail: true);
    }
  } catch (_) {
    // No static thumbnail yet, fall back to the full image.
  }

  debugPrint("Thumbnail $imageId not generated yet, serving the full image");
  final full = await supabase.storage.from('images').download(imageId);
  return (bytes: full, isThumbnail: false);
}

/// Download a profile picture from storage.
Future<SupabaseResponse<Uint8List>> getProfilePictureBytes(
    String userId) async {
  try {
    final data =
        await supabase.storage.from('profile-pictures').download(userId);
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
        await supabase.rpc("get_image_details", params: {"image_id": imageId});
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
