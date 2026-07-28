import 'package:krab/models/user.dart' as krab_user;

class GroupMember {
  final krab_user.User user;
  final String role;

  GroupMember({
    required this.user,
    required this.role,
  });

  /// Which instance this membership is on, taken from the member themselves.
  String get instanceId => user.instanceId;

  // Convert a JSON Map to a GroupMember object
  factory GroupMember.fromJson(Map<String, dynamic> json,
      {required String instanceId}) {
    return GroupMember(
      user: krab_user.User.fromJson(json['user'] as Map<String, dynamic>,
          instanceId: instanceId),
      role: json['role'] as String,
    );
  }

  // Empty
  factory GroupMember.empty({String instanceId = ''}) {
    return GroupMember(
        user: krab_user.User(
            instanceId: instanceId, id: '', username: '', pfpUrl: ''),
        role: 'member');
  }
}
