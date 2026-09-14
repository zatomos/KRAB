class Comment {
  final String id;
  final String userId;
  final String text;
  final DateTime createdAt;
  final String? parentId;
  final List<Comment> replies;
  final DateTime? deletedAt;

  Comment({
    required this.id,
    required this.userId,
    required this.text,
    required this.createdAt,
    this.parentId,
    this.deletedAt,
    List<Comment>? replies,
  }) : replies = replies ?? [];

  bool get isDeleted => deletedAt != null;

  @override
  String toString() {
    return 'Comment(id: $id, userId: $userId, text: $text, createdAt: $createdAt, parentId: $parentId, deletedAt: $deletedAt, replies: ${replies.length})';
  }
}

// Build a tree structure from flat comments list
List<Comment> buildCommentTree(List<Comment> flatComments) {
  final Map<String, Comment> commentMap = {};
  final List<Comment> rootComments = [];

  // Index comments by id
  for (final comment in flatComments) {
    commentMap[comment.id] = comment;
  }

  // Build tree
  for (final comment in flatComments) {
    if (comment.parentId == null) {
      rootComments.add(commentMap[comment.id]!);
    } else {
      final parent = commentMap[comment.parentId];
      if (parent != null) {
        parent.replies.add(comment);
      } else {
        // Orphaned comment, treat as root
        rootComments.add(comment);
      }
    }
  }

  return rootComments;
}
