import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/services/background_session.dart';
import 'package:krab/services/fcm_helper.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:krab/models/group.dart';
import 'package:krab/models/group_invite.dart';
import 'package:krab/models/group_member.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/image_details.dart';
import 'package:krab/models/user.dart' as krab_user;

final supabase = Supabase.instance.client;

/// Response Wrapper
class SupabaseResponse<T> {
  final bool success;
  final T? data;
  final String? error;

  SupabaseResponse({required this.success, this.data, this.error});
}

/// Calls a Supabase RPC that returns a `{success, error, ...}` JSON object and
/// wraps the common success/error/try-catch handling.
Future<SupabaseResponse<T>> _rpc<T>(
  String fn, {
  Map<String, dynamic>? params,
  required String errorContext,
  T Function(dynamic response)? parse,
}) async {
  try {
    final response = await supabase.rpc(fn, params: params);
    if (response is Map && response['success'] == false) {
      return SupabaseResponse(
          success: false, error: response['error']?.toString());
    }
    return SupabaseResponse(success: true, data: parse?.call(response));
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error $errorContext: $error");
  }
}

/// ------------------ GROUP FUNCTIONS ------------------

/// Get all groups for the current user.
Future<SupabaseResponse<List<Group>>> getUserGroups() async {
  try {
    final supabase = Supabase.instance.client;
    final cache = ProfilePictureCache.of(supabase);

    // Call RPC to get groups
    final response = await supabase.rpc("get_user_groups");

    if (response['success'] == true) {
      final groups = response['groups'] as List;

      // Create group list
      final List<Group> groupsList = [];
      for (final groupJson in groups) {
        final group = Group.fromJson(groupJson);

        // Get cached icon URL
        final iconUrl = await cache.getUrl(
          group.id,
          bucket: 'group-icons',
          ttl: const Duration(hours: 1),
        );

        groupsList.add(group.copyWith(iconUrl: iconUrl ?? ''));
      }

      return SupabaseResponse(success: true, data: groupsList);
    } else {
      return SupabaseResponse(
        success: false,
        error: "Error loading groups: ${response['error'] ?? 'Unknown error'}",
      );
    }
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error loading groups: $error",
    );
  }
}

/// Get group details for a given group ID.
Future<SupabaseResponse<Group>> getGroupDetails(String groupId) async {
  try {
    final supabase = Supabase.instance.client;

    // Fetch group data from RPC
    final response =
        await supabase.rpc("get_group_details", params: {"group_id": groupId});

    if (response == null ||
        response is! Map ||
        response['success'] == false ||
        response['group'] == null) {
      return SupabaseResponse(
        success: false,
        error:
            "Error loading group details: ${response?['error'] ?? 'Unknown'}",
      );
    }

    // Parse the group
    final group = Group.fromJson(response['group']);

    // Fetch cached icon URL
    final cache = ProfilePictureCache.of(supabase);
    final iconUrl = await cache.getUrl(
      group.id,
      ttl: const Duration(hours: 1),
      bucket: 'group-icons',
    );

    final groupWithIcon = group.copyWith(iconUrl: iconUrl ?? '');

    return SupabaseResponse(success: true, data: groupWithIcon);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error loading group details: $error",
    );
  }
}

/// Get count of members for a given group.
Future<SupabaseResponse<int>> getGroupMemberCount(String groupId) =>
    _rpc("get_group_members_count",
        params: {"group_id": groupId},
        errorContext: "loading group member count",
        parse: (r) => r['member_count'] as int);

/// Get members for a given group.
Future<SupabaseResponse<List<GroupMember>>> getGroupMembers(
    String groupId) async {
  try {
    final response = await supabase.rpc(
      "get_group_members",
      params: {"group_id": groupId},
    );

    if (response['success'] == false) {
      return SupabaseResponse(
        success: false,
        error: "Error loading group members: ${response['error']}",
      );
    }

    final members = response['members'] as List;
    final List<GroupMember> membersList = [];

    for (final member in members) {
      final userId = member['user_id'] as String;
      final role = member['role'] as String;

      // Fetch user info
      final userDetailsResponse = await getUserDetails(userId);

      if (userDetailsResponse.success && userDetailsResponse.data != null) {
        final user = userDetailsResponse.data!;
        membersList.add(GroupMember(user: user, role: role));
      }
    }

    debugPrint("Fetched ${membersList.length} members for group $groupId");

    return SupabaseResponse(success: true, data: membersList);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error loading group members: $error",
    );
  }
}

Future<SupabaseResponse<String>> changeMemberRole(
  String groupId,
  String targetUserId,
  String action, // 'promote_admin', 'demote', 'transfer_ownership'
) =>
    _rpc('manage_member_role',
        params: {
          'group_id': groupId,
          'target_user_id': targetUserId,
          'action': action,
        },
        errorContext: 'changing role',
        parse: (r) => r['role'] as String);

Future<SupabaseResponse<String>> banUser(String groupId, String userId) =>
    _rpc('ban_user',
        params: {'group_id': groupId, 'target_user_id': userId},
        errorContext: 'banning user',
        parse: (_) => 'banned');

Future<SupabaseResponse<String>> unbanUser(String groupId, String userId) =>
    _rpc('unban_user',
        params: {'group_id': groupId, 'target_user_id': userId},
        errorContext: 'unbanning user',
        parse: (_) => 'unbanned');

/// Edit the profile picture of the current user.
Future<SupabaseResponse<Group>> editGroupIcon(
    File imageFile, String groupId) async {
  try {
    // Upload or update the image
    final storage = supabase.storage.from("group-icons");
    final exists = await storage.exists(groupId);

    if (exists) {
      await storage.update(
        groupId,
        imageFile,
        fileOptions: const FileOptions(contentType: 'image/jpeg'),
      );
    } else {
      await storage.upload(
        groupId,
        imageFile,
        fileOptions: const FileOptions(contentType: 'image/jpeg'),
      );
    }

    // Refresh cache and get the new signed URL
    final cache = ProfilePictureCache.of(supabase);
    final iconUrl = await cache.refresh(groupId, bucket: 'group-icons');

    // Return the updated group
    final groupResponse = await getGroupDetails(groupId);
    if (!groupResponse.success || groupResponse.data == null) {
      return SupabaseResponse(
        success: true,
        data: groupResponse.data?.copyWith(iconUrl: iconUrl ?? ''),
      );
    }

    final updatedGroup = groupResponse.data!.copyWith(iconUrl: iconUrl ?? '');

    return SupabaseResponse(success: true, data: updatedGroup);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error updating group icon: $error",
    );
  }
}

/// Get the icon picture of the requested group.
Future<SupabaseResponse<String>> getGroupIconUrl(String groupId) async {
  // Force refresh
  final iconUrl = await ProfilePictureCache.of(supabase)
      .refresh(groupId, bucket: 'group-icons');

  return SupabaseResponse(
    success: true,
    data: iconUrl ?? '',
  );
}

/// Delete the icon picture of the requested group.
Future<SupabaseResponse<void>> deleteGroupIcon(String groupId) async {
  try {
    await supabase.storage.from("group-icons").remove([groupId]);
    await ProfilePictureCache.of(supabase)
        .refresh(groupId, bucket: 'group-icons');
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error deleting group icon: $error",
    );
  }
}

/// Create a new group.
Future<SupabaseResponse<void>> createGroup(String name) async {
  final res = await _rpc<void>("create_group",
      params: {"group_name": name}, errorContext: "creating group");
  // The DB rejects too-short names with a generic "new row" constraint error.
  if (!res.success && (res.error?.contains("new row") ?? false)) {
    return SupabaseResponse(success: false, error: "Name too short.");
  }
  return res;
}

/// Update the name of an existing group.
Future<SupabaseResponse<void>> updateGroupName(String groupId, String name) =>
    _rpc("update_group_name",
        params: {"group_id": groupId, "new_name": name},
        errorContext: "updating group name");

/// Delete a group.
Future<SupabaseResponse<void>> deleteGroup(String groupId) =>
    _rpc("remove_group",
        params: {"group_id": groupId}, errorContext: "deleting group");

/// Join a group using an invite token.
Future<SupabaseResponse<String>> joinGroupByInvite(String token) =>
    _rpc("join_group_by_invite",
        params: {"p_token": token.trim()},
        errorContext: "joining group",
        parse: (r) => r['group_id'] as String);

/// Create an invite token for a group. [expiresAt] and [maxUses] are optional;
/// null means the invite never expires / has unlimited uses.
Future<SupabaseResponse<String>> createGroupInvite(
  String groupId, {
  DateTime? expiresAt,
  int? maxUses,
}) =>
    _rpc("create_group_invite",
        params: {
          "p_group_id": groupId,
          "p_expires_at": expiresAt?.toUtc().toIso8601String(),
          "p_max_uses": maxUses,
        },
        errorContext: "creating invite",
        parse: (r) => r['token'] as String);

/// List a group's invites (owner/admin only).
Future<SupabaseResponse<List<GroupInvite>>> listGroupInvites(String groupId) =>
    _rpc("list_group_invites",
        params: {"p_group_id": groupId},
        errorContext: "loading invites",
        parse: (r) => (r['invites'] as List)
            .map((e) => GroupInvite.fromJson(e as Map<String, dynamic>))
            .toList());

/// Revoke an invite token.
Future<SupabaseResponse<void>> revokeGroupInvite(String token) =>
    _rpc("revoke_group_invite",
        params: {"p_token": token}, errorContext: "revoking invite");

/// Set who may create invites for a group (owner only).
/// [permission] is one of 'owner', 'admin', 'everyone'.
Future<SupabaseResponse<void>> setGroupInvitePermission(
        String groupId, String permission) =>
    _rpc("set_group_invite_permission",
        params: {"p_group_id": groupId, "p_permission": permission},
        errorContext: "updating invite permission");

/// Leave a group.
Future<SupabaseResponse<void>> leaveGroup(String groupId) => _rpc("leave_group",
    params: {"group_id": groupId}, errorContext: "leaving group");

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

/// ------------------ FCM TOKEN & USER FUNCTIONS ------------------

/// Handles FCM token registration.
Future<SupabaseResponse<void>> fcmTokenHandler({String? username}) async {
  try {
    await FirebaseMessaging.instance.requestPermission();

    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken == null) {
      return SupabaseResponse(success: false, error: "Error getting FCM token");
    }

    if (supabase.auth.currentUser == null) {
      return SupabaseResponse(success: false, error: "No authenticated user");
    }

    final response = await supabase.rpc("register_fcm_token", params: {
      "p_fcm_token": fcmToken,
      if (username != null) "p_username": username,
    });

    if (response["success"] == false) {
      return SupabaseResponse(
          success: false, error: response["error"]?.toString());
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error handling FCM token: $error",
    );
  }
}

String _authError(AuthException e) {
  switch (e.code) {
    case 'invalid_credentials':
      return 'invalid_email_or_password';
    case 'user_already_exists':
    case 'email_exists':
      return 'email_already_exists';
    case 'weak_password':
      return 'password_too_weak';
    default:
      return e.message;
  }
}

/// Register a new user.
Future<SupabaseResponse<void>> registerUser(
    String username, String email, String password) async {
  debugPrint("Registering user: $username, $email");
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

    // Mint the independent background session so they never rotate the
    // interactive session's token
    await BackgroundSession.mintAndStore(email, password);

    // Handle FCM token registration
    await fcmTokenHandler(username: username);

    return SupabaseResponse(success: true);
  } catch (error) {
    final message = error is AuthException
        ? _authError(error)
        : 'Error registering user: $error';
    return SupabaseResponse(success: false, error: message);
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
    // Mint the independent background session so they never rotate the
    // interactive session's token
    await BackgroundSession.mintAndStore(email, password);
    await fcmTokenHandler();
    return SupabaseResponse(success: true);
  } catch (error) {
    final message =
        error is AuthException ? _authError(error) : 'Error logging in: $error';
    return SupabaseResponse(success: false, error: message);
  }
}

/// Log out the current user.
Future<SupabaseResponse<void>> logOut() async {
  try {
    // Mark this as an intentional logout to prevent "unexpected signout" notification
    DebugNotifier.instance.markIntentionalLogout();

    // Clean up FCM listeners
    await FcmHelper.dispose();

    // Clear the independent background session
    await BackgroundSession.clear();

    // Clear profile picture cache
    await ProfilePictureCache.of(supabase).clear();

    // Sign out
    await supabase.auth.signOut();
    return SupabaseResponse(success: true);
  } catch (error) {
    // Reset the flag if logout fails
    DebugNotifier.instance.resetIntentionalLogout();
    return SupabaseResponse(success: false, error: "Error signing out: $error");
  }
}

/// Get the username for a given user ID.
Future<SupabaseResponse<krab_user.User>> getUserDetails(String userId) async {
  try {
    final supabase = Supabase.instance.client;

    // Get username
    final usernameResponse =
        await supabase.rpc('get_username', params: {'user_id': userId});
    if (usernameResponse == null || usernameResponse == '') {
      return SupabaseResponse(
          success: false, error: 'Could not get username for this user');
    }

    final username = usernameResponse as String;
    debugPrint("Fetched username for $userId: $username");

    // Cached signed URL
    final pfpUrl = await ProfilePictureCache.of(supabase)
        .getUrl(userId, ttl: const Duration(hours: 1));

    debugPrint("Fetched profile picture URL for $userId: $pfpUrl");

    // Construct user object
    final user = krab_user.User(
      id: userId,
      username: username,
      pfpUrl: pfpUrl ?? '',
    );

    return SupabaseResponse(success: true, data: user);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: 'Error fetching user details: $error',
    );
  }
}

/// Resolve everything an image notification needs in a single RPC call
Future<SupabaseResponse<Map<String, dynamic>>> getImageNotificationContext(
    String imageId, String groupId) async {
  try {
    final res = await supabase.rpc('get_image_notification',
        params: {'p_image_id': imageId, 'p_group_id': groupId});
    if (res == null || res['success'] != true) {
      return SupabaseResponse(success: false, error: res?['error']?.toString());
    }
    return SupabaseResponse(success: true, data: res as Map<String, dynamic>);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: 'Error fetching image notification: $error');
  }
}

/// Resolve everything a comment notification needs in a single RPC call
Future<SupabaseResponse<Map<String, dynamic>>> getCommentNotificationContext(
    String commentId) async {
  try {
    final res = await supabase
        .rpc('get_comment_notification', params: {'p_comment_id': commentId});
    if (res == null || res['success'] != true) {
      return SupabaseResponse(success: false, error: res?['error']?.toString());
    }
    return SupabaseResponse(success: true, data: res as Map<String, dynamic>);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: 'Error fetching comment notification: $error');
  }
}

/// Edit the username of the current user.
Future<SupabaseResponse<void>> editUsername(String newUsername) async {
  try {
    final user = supabase.auth.currentUser;
    if (user == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }

    await supabase.rpc("edit_username", params: {
      "new_username": newUsername,
    });

    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error updating username: $error",
    );
  }
}

/// Edit the profile picture of the current user.
Future<SupabaseResponse<void>> editProfilePicture(File imageFile) async {
  try {
    final user = supabase.auth.currentUser;
    if (user == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }

    // Check if a profile picture already exists
    if (await supabase.storage.from("profile-pictures").exists(user.id)) {
      await supabase.storage.from("profile-pictures").update(user.id, imageFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
    } else {
      await supabase.storage.from("profile-pictures").upload(user.id, imageFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
    }

    await ProfilePictureCache.of(supabase).refresh(user.id);

    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error updating profile picture: $error",
    );
  }
}

/// Get the profile picture of the requested user.
Future<SupabaseResponse<String>> getProfilePictureUrl(String userId) async {
  // Force refresh
  final pfpUrl = await ProfilePictureCache.of(supabase).refresh(userId);

  return SupabaseResponse(
    success: true,
    data: pfpUrl ?? '',
  );
}

/// Delete the profile picture of the current user.
Future<SupabaseResponse<void>> deleteProfilePicture() async {
  try {
    final user = supabase.auth.currentUser;
    if (user == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }
    await supabase.storage.from("profile-pictures").remove([user.id]);
    await ProfilePictureCache.of(supabase).refresh(user.id);
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error deleting profile picture: $error",
    );
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

/// Change the password of the current user, verifying the current password first.
Future<SupabaseResponse<void>> changePassword(
    String currentPassword, String newPassword) async {
  try {
    final email = supabase.auth.currentUser?.email;
    if (email == null) {
      return SupabaseResponse(success: false, error: 'No authenticated user.');
    }
    await supabase.auth
        .signInWithPassword(email: email, password: currentPassword);
    await supabase.auth.updateUser(UserAttributes(password: newPassword));
    // Revoke the old background sessions server-side, then re-mint with the new
    // password so no stale background tokens linger after a password change.
    await BackgroundSession.clear();
    await BackgroundSession.mintAndStore(email, newPassword);
    return SupabaseResponse(success: true);
  } catch (error) {
    final message = error is AuthException
        ? _authError(error)
        : 'Error changing password: $error';
    return SupabaseResponse(success: false, error: message);
  }
}

/// Send a password reset email.
Future<SupabaseResponse<void>> sendPasswordResetEmail(String email) async {
  try {
    final redirectUrl = dotenv.env['PASSWORD_RESET_URL'] ??
        'https://your-domain.com/reset-password.html';
    await supabase.auth.resetPasswordForEmail(email, redirectTo: redirectUrl);
    return SupabaseResponse(success: true);
  } catch (error) {
    final message = error is AuthException
        ? _authError(error)
        : 'Error sending password reset email: $error';
    return SupabaseResponse(success: false, error: message);
  }
}

/// Set setting to receive notifications about new comments under other users' images.
Future<SupabaseResponse<void>> setGroupCommentNotificationSetting(
        bool enabled) =>
    _rpc("set_notify_group_comments",
        params: {"enabled": enabled},
        errorContext: "updating notification setting");

Future<SupabaseResponse<bool>> getGroupCommentNotificationSetting() =>
    _rpc("get_notify_group_comments",
        errorContext: "fetching notification setting",
        parse: (r) => r['enabled'] as bool);
