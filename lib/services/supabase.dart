import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:krab/models/Group.dart';

final supabase = Supabase.instance.client;

/// Response Wrapper
class SupabaseResponse<T> {
  final bool success;
  final T? data;
  final String? error;

  SupabaseResponse({required this.success, this.data, this.error});
}

/// ------------------ GROUP FUNCTIONS ------------------

/// Get all groups for the current user.
Future<SupabaseResponse<List<Group>>> getUserGroups() async {
  try {
    final response = await supabase.rpc("get_user_groups");
    if (response['success'] == true) {
      final groups = response['groups'] as List;
      final List<Group> groupsList =
          groups.map((group) => Group.fromJson(group)).toList();
      return SupabaseResponse(success: true, data: groupsList);
    } else {
      return SupabaseResponse(
          success: false,
          error:
              "Error loading groups: ${response['error'] ?? 'Unknown error'}");
    }
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading groups: $error");
  }
}

/// Get group details for a given group ID.
Future<SupabaseResponse<Group>> getGroupDetails(String groupId) async {
  try {
    final response =
        await supabase.rpc("get_group_details", params: {"group_id": groupId});
    if (response['success'] == false) {
      return SupabaseResponse(
          success: false,
          error: "Error loading group details: ${response['error']}");
    }
    final group = Group.fromJson(response['group']);
    return SupabaseResponse(success: true, data: group);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading group details: $error");
  }
}

/// Get count of members for a given group.
Future<SupabaseResponse<int>> getGroupMemberCount(String groupId) async {
  try {
    final response = await supabase
        .rpc("get_group_members_count", params: {"group_id": groupId});
    if (response['success'] == false) {
      return SupabaseResponse(
          success: false,
          error: "Error loading group member count: ${response['error']}");
    }
    return SupabaseResponse(
        success: true, data: response['member_count'] as int);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading group member count: $error");
  }
}

/// Get members for a given group.
Future<SupabaseResponse<List<dynamic>>> getGroupMembers(String groupId) async {
  try {
    final response =
        await supabase.rpc("get_group_members", params: {"group_id": groupId});
    if (response['success'] == false) {
      return SupabaseResponse(
          success: false,
          error: "Error loading group members: ${response['error']}");
    }
    return SupabaseResponse(success: true, data: response['members'] as List);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading group members: $error");
  }
}

/// Check if the current user is admin in a group.
Future<SupabaseResponse<bool>> isAdmin(String groupId) async {
  try {
    final response =
        await supabase.rpc("is_admin", params: {"group_id": groupId});
    return SupabaseResponse(success: true, data: response as bool);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error checking admin status: $error");
  }
}

/// Create a new group.
Future<SupabaseResponse<void>> createGroup(String name) async {
  try {
    final response =
        await supabase.rpc("create_group", params: {"group_name": name});
    if (response['success'] == false) {
      if (response['error'].toString().contains("new row")) {
        return SupabaseResponse(success: false, error: "Name too short.");
      }
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error creating group: $error");
  }
}

/// Update the name of an existing group.
Future<SupabaseResponse<void>> updateGroupName(
    String groupId, String name) async {
  try {
    final response = await supabase.rpc("update_group_name",
        params: {"group_id": groupId, "new_name": name});
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error updating group name: $error");
  }
}

/// Delete a group.
Future<SupabaseResponse<void>> deleteGroup(String groupId) async {
  try {
    final response =
        await supabase.rpc("remove_group", params: {"group_id": groupId});
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error deleting group: $error");
  }
}

/// Join a group using a code.
Future<SupabaseResponse<void>> joinGroup(String code) async {
  try {
    // Normalize code to lowercase
    code = code.toLowerCase();
    final response =
        await supabase.rpc("join_group_by_code", params: {"group_code": code});
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error joining group: $error");
  }
}

/// Leave a group.
Future<SupabaseResponse<void>> leaveGroup(String groupId) async {
  try {
    final response =
        await supabase.rpc("leave_group", params: {"group_id": groupId});
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error leaving group: $error");
  }
}

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
Future<SupabaseResponse<List<dynamic>>> getGroupImages(String groupId) async {
  try {
    final response =
        await supabase.rpc("get_group_images", params: {"p_group_id": groupId});
    if (response['success'] == false) {
      return SupabaseResponse(
          success: false,
          error: "Error loading group images: ${response['error']}");
    }
    return SupabaseResponse(success: true, data: response['images'] as List);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading group images: $error");
  }
}

/// Get all images.
Future<SupabaseResponse<List<dynamic>>> getAllImages() async {
  try {
    final response = await supabase.rpc("get_all_images");
    if (response['success'] == false) {
      return SupabaseResponse(
          success: false, error: "Error loading images: ${response['error']}");
    }
    return SupabaseResponse(success: true, data: response['images'] as List);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading images: $error");
  }
}

/// Get the ID of the latest image the user has access to.
Future<SupabaseResponse<String>> getLatestImage() async {
  try {
    final response = await supabase.rpc("get_latest_image");
    if (response['success'] == false) {
      return SupabaseResponse(
          success: false,
          error: "Error loading latest image: ${response['error']}");
    }
    final latestImageId = response['latest_image']['id'] as String;
    return SupabaseResponse(success: true, data: latestImageId);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading latest image: $error");
  }
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

/// Get detailed information about an image.
Future<SupabaseResponse<Map<String, dynamic>>> getImageDetails(
    String imageId) async {
  try {
    final response =
        await supabase.rpc("get_image_details", params: {"image_id": imageId});
    if (response == null || response.isEmpty) {
      return SupabaseResponse(success: false, error: "No image details found");
    }
    return SupabaseResponse(
        success: true, data: response.first as Map<String, dynamic>);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error fetching image details: $error");
  }
}

Future<SupabaseResponse<void>> postComment(
    String imageId, String groupId, String comment) async {
  try {
    final response = await supabase.rpc("add_comment", params: {
      "image_id": imageId,
      "group_id": groupId,
      "text": comment,
    });
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error posting comment: $error");
  }
}

Future<SupabaseResponse<void>> updateComment(
    String imageId, String groupId, String text) async {
  try {
    final response = await supabase.rpc("update_comment", params: {
      "image_id": imageId,
      "group_id": groupId,
      "text": text,
    });
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error updating comment: $error");
  }
}

Future<SupabaseResponse<void>> deleteComment(
    String imageId, String groupId) async {
  try {
    final response = await supabase.rpc("delete_comment", params: {
      "image_id": imageId,
      "group_id": groupId,
    });
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error deleting comment: $error");
  }
}

Future<SupabaseResponse<List<dynamic>>> getComments(
    String imageId, String groupId) async {
  try {
    final response = await supabase.rpc("get_comments", params: {
      "image_id": imageId,
      "group_id": groupId,
    });
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }

    // If there are no comments, return an empty list
    if (response['comments'] == null) {
      return SupabaseResponse(success: true, data: []);
    }

    return SupabaseResponse(success: true, data: response['comments'] as List);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading comments: $error");
  }
}

Future<SupabaseResponse<int>> getCommentCount(
    String imageId, String groupId) async {
  try {
    final response = await supabase.rpc("get_comment_count", params: {
      "image_id": imageId,
      "group_id": groupId,
    });
    if (response['success'] == false) {
      return SupabaseResponse(success: false, error: response['error']);
    }
    return SupabaseResponse(success: true, data: response['count'] as int);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading comment count: $error");
  }
}

/// ------------------ FCM TOKEN & USER FUNCTIONS ------------------

/// Handles FCM token registration.
Future<SupabaseResponse<void>> fcmTokenHandler({String? username}) async {
  try {
    // Ask permission (don’t fail if denied here; you can decide policy)
    await FirebaseMessaging.instance.requestPermission();

    // iOS-only: APNs token (optional)
    // if (Platform.isIOS) { await FirebaseMessaging.instance.getAPNSToken(); }

    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken == null) {
      return SupabaseResponse(success: false, error: "Error getting FCM token");
    }

    final user = supabase.auth.currentUser;
    if (user == null) {
      return SupabaseResponse(success: false, error: "No authenticated user");
    }

    final payload = <String, dynamic>{
      'id': user.id,
      'fcm_token': fcmToken,
      if (username != null) 'username': username,
    };

    await supabase.from('Users').upsert(payload);

    return SupabaseResponse(success: true); // <-- return it
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error handling FCM token: $error",
    );
  }
}

/// Register a new user.
Future<SupabaseResponse<void>> registerUser(
    String username, String email, String password) async {
  print("Registering user: $username, $email");
  try {
    final authResponse =
        await supabase.auth.signUp(email: email, password: password);

    if (authResponse.user == null) {
      return SupabaseResponse(
          success: false, error: "No user returned during sign up");
    }

    // Sign in the user
    final signInResponse = await supabase.auth
        .signInWithPassword(email: email, password: password);

    if (signInResponse.user == null) {
      return SupabaseResponse(
          success: false, error: "Failed to sign in after sign up");
    }

    // Handle FCM token registration
    await fcmTokenHandler(username: username);

    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error registering user: ${error.toString()}");
  }
}

/// Log in an existing user.
Future<SupabaseResponse<void>> loginUser(String email, String password) async {
  try {
    final authResponse = await supabase.auth
        .signInWithPassword(email: email, password: password);
    if (authResponse.user == null) {
      return SupabaseResponse(
          success: false, error: "No user returned during login");
    }
    await fcmTokenHandler();
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(success: false, error: "Error logging in: $error");
  }
}

/// Log out the current user.
Future<SupabaseResponse<void>> logOut() async {
  try {
    await supabase.auth.signOut();
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(success: false, error: "Error signing out: $error");
  }
}

/// Get the username for a given user ID.
Future<SupabaseResponse<String>> getUsername(String userId) async {
  try {
    final response =
        await supabase.rpc("get_username", params: {"user_id": userId});
    if (response == "" || response == null) {
      return SupabaseResponse(success: false, error: "Could not get username");
    }
    return SupabaseResponse(success: true, data: response as String);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error loading username: $error");
  }
}

/// Get the email of the current user.
Future<SupabaseResponse<String>> getEmail() async {
  try {
    final user = supabase.auth.currentUser;
    if (user == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }
    return SupabaseResponse(success: true, data: user.email);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error getting email: $error");
  }
}

/// Send a password reset email.
Future<SupabaseResponse<void>> sendPasswordResetEmail(String email) async {
  try {
    await supabase.auth.resetPasswordForEmail(email);
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error sending password reset email: $error");
  }
}
