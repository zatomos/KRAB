import 'dart:convert';

class Comment {
  final String userId;
  final String text;
  final DateTime createdAt;

  Comment({
    required this.userId,
    required this.text,
    required this.createdAt,
  });
}

// Convert a JSON Map to a Comment object
Comment commentFromJson(Map<String, dynamic> json) {
  return Comment(
    userId: json['user_id'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

// Convert a Comment object to a JSON Map
Map<String, dynamic> commentToJson(Comment comment) {
  return {
    'user_id': comment.userId,
    'text': comment.text,
    'created_at': comment.createdAt.toIso8601String(),
  };
}

// Convert a JSON string into a Comment object
Comment commentFromJsonString(String jsonString) {
  return commentFromJson(json.decode(jsonString));
}

// Convert a Comment object into a JSON string
String commentToJsonString(Comment comment) {
  return json.encode(commentToJson(comment));
}