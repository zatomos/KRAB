part of 'supabase.dart';

/// ------------------ IMAGE FUNCTIONS ------------------

/// Send an image to selected groups with an optional description.
Future<SupabaseResponse<String>> sendImageToGroups(
  File imageFile,
  List<String> selectedGroups,
  String description,
) async {
  try {
    // Request UUID
    final uuidResponse =
        await _withRetry(() => supabase.rpc("request_image_uuid"));

    if (uuidResponse['success'] == false) {
      return SupabaseResponse(
        success: false,
        error: "Error requesting UUID: ${uuidResponse['error']}",
      );
    }

    final String imageId = uuidResponse['image_id'] as String;

    // Upload image to storage
    try {
      await _withRetry(() => supabase.storage.from("images").upload(
            imageId,
            imageFile,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          ));
    } catch (uploadError) {
      return SupabaseResponse(
        success: false,
        error: "Error uploading image: $uploadError",
      );
    }

    // Register image in database
    final regResponse =
        await _withRetry(() => supabase.rpc("register_uploaded_image", params: {
              "image_id": imageId,
              "group_ids": selectedGroups,
              "image_description": description,
            }));

    if (regResponse['success'] == false) {
      return SupabaseResponse(
        success: false,
        error: "Error registering image in database: ${regResponse['error']}",
      );
    }

    return SupabaseResponse(success: true, data: imageId);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error sending image: $error",
    );
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

/// Get the [count] most recent images accessible to the user, deduplicated
/// across groups.
/// If groupIds is provided and non-empty, only images from those groups are
/// returned; otherwise images from all accessible groups are included.
Future<SupabaseResponse<List<ImageRef>>> getLatestImages(
  int count, {
  List<String>? groupIds,
  DateTime? beforeCreatedAt,
  String? beforeId,
}) {
  final params = <String, dynamic>{"p_count": count};
  if (groupIds != null && groupIds.isNotEmpty) {
    params["p_group_ids"] = groupIds;
  }
  if (beforeCreatedAt != null) {
    params["p_before_created_at"] = beforeCreatedAt.toIso8601String();
  }
  if (beforeId != null) {
    params["p_before_id"] = beforeId;
  }
  return _rpc("get_latest_images",
      params: params,
      errorContext: "loading latest images",
      parse: (r) => (r['images'] as List)
          .map((e) => ImageRef.fromJson(e as Map<String, dynamic>))
          .toList());
}

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

    if (lowRes) {
      data = await _downloadThumbnail(imageId);
    } else {
      // Fullres download
      data = await supabase.storage.from('images').download(imageId);
    }

    if (data.isEmpty) {
      return SupabaseResponse(
        success: false,
        error: "Downloaded image is empty",
      );
    }

    // Populate the disk cache for next time.
    unawaited(ImageDiskCache.instance.write(cacheKey, data));

    return SupabaseResponse(success: true, data: data);
  } catch (error, stack) {
    debugPrint("Error downloading image $imageId: $error");
    debugPrint(stack.toString());
    return SupabaseResponse(
      success: false,
      error: "Error downloading image: $error",
    );
  }
}

/// Fetch an image's thumbnail. Prefers the pre-generated static thumbnail;
/// when it isn't there, it falls back to the full image.
Future<Uint8List> _downloadThumbnail(String imageId) async {
  try {
    final data =
        await supabase.storage.from(_thumbnailsBucket).download(imageId);
    if (data.isNotEmpty) {
      debugPrint("Thumbnail $imageId served statically");
      return data;
    }
  } catch (_) {
    // No static thumbnail yet, fall back to the full image.
  }

  return supabase.storage.from('images').download(imageId);
}

/// Download a profile picture from storage.
Future<SupabaseResponse<Uint8List>> getProfilePictureBytes(
    String userId) async {
  try {
    final data =
        await supabase.storage.from('profile-pictures').download(userId);
    if (data.isEmpty) {
      return SupabaseResponse(
          success: false, error: 'Profile picture is empty');
    }
    return SupabaseResponse(success: true, data: data);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: 'Error downloading profile picture: $error',
    );
  }
}

/// Get detailed information about an image.
Future<SupabaseResponse<ImageDetails>> getImageDetails(String imageId) async {
  try {
    final response =
        await supabase.rpc("get_image_details", params: {"image_id": imageId});
    if (response == null || response.isEmpty) {
      return SupabaseResponse(success: false, error: "No image details found");
    }
    return SupabaseResponse(
        success: true,
        data: ImageDetails.fromJson(response.first as Map<String, dynamic>));
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error fetching image details: $error");
  }
}

Future<SupabaseResponse<void>> postComment(
        String imageId, String groupId, String comment,
        {String? parentId}) =>
    _rpc("add_comment",
        params: {
          "image_id": imageId,
          "group_id": groupId,
          "text": comment,
          if (parentId != null) "parent_id": parentId,
        },
        errorContext: "posting comment");

Future<SupabaseResponse<void>> updateComment(
        String commentId, String imageId, String groupId, String text) =>
    _rpc("update_comment",
        params: {
          "comment_id": commentId,
          "image_id": imageId,
          "group_id": groupId,
          "text": text,
        },
        errorContext: "updating comment");

Future<SupabaseResponse<void>> deleteComment(
        String commentId, String imageId, String groupId) =>
    _rpc("delete_comment",
        params: {
          "comment_id": commentId,
          "image_id": imageId,
          "group_id": groupId,
        },
        errorContext: "deleting comment");

Future<SupabaseResponse<List<dynamic>>> getComments(
        String imageId, String groupId) =>
    _rpc("get_comments",
        params: {"image_id": imageId, "group_id": groupId},
        errorContext: "loading comments",
        parse: (r) => (r['comments'] as List?) ?? []);

Future<SupabaseResponse<int>> getCommentCount(String imageId, String groupId) =>
    _rpc("get_comment_count",
        params: {"image_id": imageId, "group_id": groupId},
        errorContext: "loading comment count",
        parse: (r) => r['count'] as int);

/// Total number of comments an image received across every group the current
/// user is a member of
Future<SupabaseResponse<int>> getImageCommentCount(String imageId) =>
    _rpc("get_image_comment_count",
        params: {"p_image_id": imageId},
        errorContext: "loading comment count",
        parse: (r) => r['count'] as int);

/// Every group the current user shares an image with
Future<SupabaseResponse<List<dynamic>>> getImageGroups(String imageId) =>
    _rpc("get_image_groups",
        params: {"p_image_id": imageId},
        errorContext: "loading groups",
        parse: (r) => (r['groups'] as List?) ?? []);

/// Comments for an image grouped by every group the current user shares it
/// with. When primaryGroupId is provided, that group is returned first and
/// flagged as primary.
Future<SupabaseResponse<List<dynamic>>> getImageCommentsGrouped(String imageId,
        {String? primaryGroupId}) =>
    _rpc("get_image_comments_grouped",
        params: {
          "p_image_id": imageId,
          if (primaryGroupId != null) "p_primary_group_id": primaryGroupId,
        },
        errorContext: "loading comments",
        parse: (r) => (r['groups'] as List?) ?? []);
