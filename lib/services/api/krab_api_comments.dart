part of 'krab_api.dart';

/// ------------------ COMMENT FUNCTIONS ------------------

/// How many comments an image has, and when the newest of them arrived.
class CommentTally {
  const CommentTally({required this.count, this.latestAt});

  final int count;
  final DateTime? latestAt;

  static CommentTally fromJson(dynamic raw) {
    final map = raw is Map ? raw : const {};
    return CommentTally(
      count: (map['count'] as num?)?.toInt() ?? 0,
      latestAt: DateTime.tryParse(map['latest_comment_at']?.toString() ?? ''),
    );
  }

  /// The newest of two tallies' times, for a count merged across servers.
  static DateTime? newest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}

extension KrabApiComments on KrabApi {
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

  Future<SupabaseResponse<CommentTally>> getCommentCount(
          String imageId, String groupId) =>
      _rpc("get_comment_count",
          params: {"image_id": imageId, "group_id": groupId},
          errorContext: "loading comment count",
          parse: CommentTally.fromJson);

  /// Total number of comments an image received across every group the current
  /// user is a member of
  Future<SupabaseResponse<CommentTally>> getImageCommentCount(String imageId) =>
      _rpc("get_image_comment_count",
          params: {"p_image_id": imageId},
          errorContext: "loading comment count",
          parse: CommentTally.fromJson);

  /// Every group the current user shares an image with
  Future<SupabaseResponse<List<dynamic>>> getImageGroups(String imageId) =>
      _rpc("get_image_groups",
          params: {"p_image_id": imageId},
          errorContext: "loading groups",
          parse: (r) => (r['groups'] as List?) ?? []);

  /// Comments for an image grouped by every group the current user shares it
  /// with. When primaryGroupId is provided, that group is returned first and
  /// flagged as primary.
  Future<SupabaseResponse<List<dynamic>>> getImageCommentsGrouped(
          String imageId,
          {String? primaryGroupId}) =>
      _rpc("get_image_comments_grouped",
          params: {
            "p_image_id": imageId,
            if (primaryGroupId != null) "p_primary_group_id": primaryGroupId,
          },
          errorContext: "loading comments",
          parse: (r) => (r['groups'] as List?) ?? []);
}
