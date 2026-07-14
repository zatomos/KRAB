import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/auth/app_auth.dart';

class User {
  final String id;
  final String username;
  final String pfpUrl;

  const User({
    required this.id,
    required this.username,
    this.pfpUrl = '',
  });

  User copyWith({
    String? id,
    String? username,
    String? pfpUrl,
  }) {
    pfpUrl ??= '';
    return User(
        id: id ?? this.id, username: username ?? this.username, pfpUrl: pfpUrl);
  }

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      username: json['username'] as String,
      pfpUrl: json['pfp_url'] as String? ?? '',
    );
  }

  @override
  String toString() {
    return 'User{id: $id, username: $username, pfpUrl: $pfpUrl}';
  }
}

Future<User> getCurrentUser() async {
  final userId = AppAuth.instance.currentUserId;
  if (userId == null) {
    throw Exception('No authenticated user found');
  }

  final response = await getUserDetails(userId);
  if (!response.success || response.data == null) {
    throw Exception('Failed to fetch user details for $userId');
  }

  final krabUser = response.data!;
  return User(
    id: userId,
    username: krabUser.username,
    pfpUrl: krabUser.pfpUrl,
  );
}
