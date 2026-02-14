import 'dart:convert';

class Comment {
  final String id;
  final String userId;
  final String text;
  final DateTime createdAt;
  final String? parentId;
  final List<Comment> replies;

  Comment({
    required this.id,
    required this.userId,
    required this.text,
    required this.createdAt,
    this.parentId,
    List<Comment>? replies,
  }) : replies = replies ?? [];

  Comment copyWith({
    String? id,
    String? userId,
    String? text,
    DateTime? createdAt,
    String? parentId,
    List<Comment>? replies,
  }) {
    return Comment(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      parentId: parentId ?? this.parentId,
      replies: replies ?? this.replies,
    );
  }

  @override
  String toString() {
    return 'Comment(id: $id, userId: $userId, text: $text, createdAt: $createdAt, parentId: $parentId, replies: ${replies.length})';
  }
}

// Convert a JSON Map to a Comment object
Comment commentFromJson(Map<String, dynamic> json) {
  return Comment(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    parentId: json['parent_id'] as String?,
  );
}

// Convert a Comment object to a JSON Map
Map<String, dynamic> commentToJson(Comment comment) {
  return {
    'id': comment.id,
    'user_id': comment.userId,
    'text': comment.text,
    'created_at': comment.createdAt.toIso8601String(),
    'parent_id': comment.parentId,
  };
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

// Convert a JSON string into a Comment object
Comment commentFromJsonString(String jsonString) {
  return commentFromJson(json.decode(jsonString));
}

// Convert a Comment object into a JSON string
String commentToJsonString(Comment comment) {
  return json.encode(commentToJson(comment));
}