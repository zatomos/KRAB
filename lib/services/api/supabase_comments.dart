part of 'supabase.dart';

/// ------------------ COMMENT FUNCTIONS ------------------

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
