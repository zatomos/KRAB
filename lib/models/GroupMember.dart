import 'package:krab/models/User.dart' as KrabUser;
class GroupMember {
  final KrabUser.User user;
  final String role;

  GroupMember({
    required this.user,
    required this.role,
  });

  // Convert a JSON Map to a GroupMember object
  factory GroupMember.fromJson(Map<String, dynamic> json) {
    return GroupMember(
      user: KrabUser.User.fromJson(json['user'] as Map<String, dynamic>),
      role: json['role'] as String,
    );
  }

  // Empty
  factory GroupMember.empty() {
    return GroupMember(
      user: const KrabUser.User(id: '', username: '', pfpUrl: ''),
      role: 'member'
    );
  }
}