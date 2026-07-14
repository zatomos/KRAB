part of 'supabase.dart';

/// ------------------ GROUP FUNCTIONS ------------------

/// Get all groups for the current user.
Future<SupabaseResponse<List<Group>>> getUserGroups() async {
  final res = await _rpc<List<Group>>("get_user_groups",
      errorContext: "loading groups",
      parse: (r) => (r['groups'] as List).map((g) => Group.fromJson(g)).toList());
  if (!res.success || res.data == null) return res;

  // Resolve icon URLs in parallel from the (cached) signed-URL store.
  final cache = ProfilePictureCache.of(supabase);
  final groupsList = await Future.wait(res.data!.map((group) async {
    final iconUrl = await cache.getUrl(
      group.id,
      bucket: 'group-icons',
      ttl: const Duration(hours: 1),
    );
    return group.copyWith(iconUrl: iconUrl ?? '');
  }));
  return SupabaseResponse(success: true, data: groupsList);
}

/// Get group details for a given group ID.
Future<SupabaseResponse<Group>> getGroupDetails(String groupId) async {
  final res = await _rpc<Group>("get_group_details",
      params: {"group_id": groupId},
      errorContext: "loading group details",
      parse: (r) => Group.fromJson(r['group']));
  if (!res.success || res.data == null) return res;

  // Fetch cached icon URL
  final iconUrl = await ProfilePictureCache.of(supabase).getUrl(
    groupId,
    ttl: const Duration(hours: 1),
    bucket: 'group-icons',
  );
  return SupabaseResponse(
      success: true, data: res.data!.copyWith(iconUrl: iconUrl ?? ''));
}

/// Whether the current user is an owner or admin of the group.
Future<SupabaseResponse<bool>> isGroupAdminOrOwner(String groupId) =>
    _rpc<bool>("is_admin_or_owner",
        params: {"p_group_id": groupId},
        errorContext: "loading group role",
        parse: (r) => r == true);

/// Get count of members for a given group.
Future<SupabaseResponse<int>> getGroupMemberCount(String groupId) =>
    _rpc("get_group_members_count",
        params: {"group_id": groupId},
        errorContext: "loading group member count",
        parse: (r) => r['member_count'] as int);

/// Get members for a given group.
Future<SupabaseResponse<List<GroupMember>>> getGroupMembers(
    String groupId) async {
  final res = await _rpc<List<Map<String, dynamic>>>("get_group_members",
      params: {"group_id": groupId},
      errorContext: "loading group members",
      parse: (r) => (r['members'] as List).cast<Map<String, dynamic>>());
  if (!res.success || res.data == null) {
    return SupabaseResponse(success: false, error: res.error);
  }

  // Resolve each member's profile picture URL from the (cached) store.
  final cache = ProfilePictureCache.of(supabase);
  final membersList = await Future.wait(res.data!.map((member) async {
    final userId = member['user_id'] as String;
    final pfpUrl = await cache.getUrl(userId, ttl: const Duration(hours: 1));
    return GroupMember(
      user: krab_user.User(
        id: userId,
        username: member['username'] as String? ?? '',
        pfpUrl: pfpUrl ?? '',
      ),
      role: member['role'] as String,
    );
  }));
  return SupabaseResponse(success: true, data: membersList);
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
    await evictAvatar(groupId);

    // The icon is uploaded either way; only the re-read of the group failed. Say
    // so, rather than reporting success with no group attached.
    final groupResponse = await getGroupDetails(groupId);
    if (!groupResponse.success || groupResponse.data == null) {
      return SupabaseResponse(
        success: false,
        error: groupResponse.error ?? "Icon updated, but the group could not be reloaded",
      );
    }

    return SupabaseResponse(
      success: true,
      data: groupResponse.data!.copyWith(iconUrl: iconUrl ?? ''),
    );
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error updating group icon: $error",
    );
  }
}

/// Resolve the signed icon URL for a group, or null if it has none.
Future<String?> resolveGroupIconUrl(String groupId) =>
    ProfilePictureCache.of(supabase).getUrl(
      groupId,
      bucket: 'group-icons',
      ttl: const Duration(hours: 1),
    );

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
    await evictAvatar(groupId);
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
