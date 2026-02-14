import 'package:krab/models/user.dart' as krab_user;
class GroupMember {
  final krab_user.User user;
  final String role;

  GroupMember({
    required this.user,
    required this.role,
  });

  // Convert a JSON Map to a GroupMember object
  factory GroupMember.fromJson(Map<String, dynamic> json) {
    return GroupMember(
      user: krab_user.User.fromJson(json['user'] as Map<String, dynamic>),
      role: json['role'] as String,
    );
  }

  // Empty
  factory GroupMember.empty() {
    return GroupMember(
      user: const krab_user.User(id: '', username: '', pfpUrl: ''),
      role: 'member'
    );
  }
}