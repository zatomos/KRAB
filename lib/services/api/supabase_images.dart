part of 'supabase.dart';

/// ------------------ IMAGE FUNCTIONS ------------------

/// Send an image to selected groups with an optional description.
Future<SupabaseResponse<void>> sendImageToGroups(
  File imageFile,
  List<String> selectedGroups,
  String description,
) async {
  try {
    // Request UUID
    final uuidResponse = await supabase.rpc("request_image_uuid");

    if (uuidResponse['success'] == false) {
      return SupabaseResponse(
        success: false,
        error: "Error requesting UUID: ${uuidResponse['error']}",
      );
    }

    final imageId = uuidResponse['image_id'];

    // Upload image to storage
    try {
      await supabase.storage.from("images").upload(imageId, imageFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
    } catch (uploadError) {
      return SupabaseResponse(
        success: false,
        error: "Error uploading image: $uploadError",
      );
    }

    // Register image in database
    final regResponse = await supabase.rpc("register_uploaded_image", params: {
      "image_id": imageId,
      "group_ids": selectedGroups,
      "image_description": description,
    });

    if (regResponse['success'] == false) {
      return SupabaseResponse(
        success: false,
        error: "Error registering image in database: ${regResponse['error']}",
      );
    }

    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error sending image: $error",
    );
  }
}

/// Get images for a given group.
Future<SupabaseResponse<List<ImageRef>>> getGroupImages(String groupId) =>
    _rpc("get_group_images",
        params: {"p_group_id": groupId},
        errorContext: "loading group images",
        parse: (r) => (r['images'] as List)
            .map((e) => ImageRef.fromJson(e as Map<String, dynamic>))
            .toList());

/// Get the n most recent images accessible to the user, deduplicated
/// across groups.
/// If groupIds is provided and non-empty, only images from those groups are
/// returned; otherwise images from all accessible groups are included.
Future<SupabaseResponse<List<ImageRef>>> getLatestImages(int count,
    {List<String>? groupIds}) {
  final params = <String, dynamic>{"p_count": count};
  if (groupIds != null && groupIds.isNotEmpty) {
    params["p_group_ids"] = groupIds;
  }
  return _rpc("get_latest_images",
      params: params,
      errorContext: "loading latest images",
      parse: (r) => (r['images'] as List)
          .map((e) => ImageRef.fromJson(e as Map<String, dynamic>))
          .toList());
}

/// Download an image from storage.
Future<SupabaseResponse<Uint8List>> getImage(String imageId,
    {bool lowRes = false}) async {
  try {
    debugPrint(
        "Downloading image $imageId with transform: ${lowRes ? 'low' : 'full'}");

    Uint8List data;

    if (lowRes) {
      // Try with transform
      try {
        data = await supabase.storage.from('images').download(
              imageId,
              transform: const TransformOptions(width: 400, quality: 50),
            );
        debugPrint("Successfully downloaded low-res image for $imageId");
      } catch (e) {
        // Fallback to full image
        debugPrint(
            "Low-res transform failed for $imageId, falling back to full image. Error: $e");
        data = await supabase.storage.from('images').download(imageId);
      }
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
