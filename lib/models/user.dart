class User {
  /// Which instance this account belongs to. The same person on two servers is
  /// two unrelated users, so the id alone never identifies anyone.
  final String instanceId;

  final String id;
  final String username;
  final String pfpUrl;

  const User({
    required this.instanceId,
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
        instanceId: instanceId,
        id: id ?? this.id,
        username: username ?? this.username,
        pfpUrl: pfpUrl);
  }

  factory User.fromJson(Map<String, dynamic> json,
      {required String instanceId}) {
    return User(
      instanceId: instanceId,
      id: json['id'] as String,
      username: json['username'] as String,
      pfpUrl: json['pfp_url'] as String? ?? '',
    );
  }

  @override
  String toString() {
    return 'User{instanceId: $instanceId, id: $id, username: $username, pfpUrl: $pfpUrl}';
  }
}
