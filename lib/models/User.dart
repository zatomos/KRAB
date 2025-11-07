import 'dart:convert';

class User {
  final String id;
  final String username;
  final String pfpUrl;

  const User({
    required this.id,
    required this.username,
    this.pfpUrl = '',
  });

  // Create a copy of the User object
  User copyWith({
    String? id,
    String? username,
    String? pfpUrl,
  }) {
    pfpUrl ??= '';
    return User(
      id: id ?? this.id,
      username: username ?? this.username,
      pfpUrl: pfpUrl
    );
  }

  // Convert a JSON Map to a User object
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      username: json['username'] as String,
      pfpUrl: json['pfp_url'] as String? ?? '',
    );
  }

  // Convert a User object to a JSON Map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'pfp_url': pfpUrl,
    };
  }

  // Convert a JSON string into a User object
  static User fromJsonString(String jsonString) {
    return User.fromJson(json.decode(jsonString));
  }

  // Convert a User object into a User string
  String toJsonString() {
    return json.encode(toJson());
  }

  @override
  String toString() {
    return 'User{id: $id, username: $username}';
  }
}
