class Group {
  final String id;
  final String name;
  final String? iconUrl;
  final String createdAt;
  final DateTime? latestImageAt;
  final String? invitePermission;
  final String? role;

  Group({
    required this.id,
    required this.name,
    this.iconUrl,
    required this.createdAt,
    this.latestImageAt,
    this.invitePermission,
    this.role,
  });

  // Convert a JSON Map to a Group object
  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      id: json['id'] as String,
      name: json['name'] as String,
      iconUrl: json['icon_url'] as String?,
      createdAt: json['created_at'] as String,
      latestImageAt: json['latest_image_at'] != null
          ? DateTime.parse(json['latest_image_at'] as String)
          : null,
      invitePermission: json['invite_permission'] as String?,
      role: json['role'] as String?,
    );
  }

  Group copyWith({
    String? id,
    String? name,
    String? iconUrl,
    String? createdAt,
    String? latestImageAt,
    String? invitePermission,
    String? role,
  }) {
    return Group(
      id: id ?? this.id,
      name: name ?? this.name,
      iconUrl: iconUrl ?? this.iconUrl,
      createdAt: createdAt ?? this.createdAt,
      latestImageAt: latestImageAt != null
          ? DateTime.parse(latestImageAt)
          : this.latestImageAt,
      invitePermission: invitePermission ?? this.invitePermission,
      role: role ?? this.role,
    );
  }

  @override
  String toString() {
    return 'Group{id: $id, name: $name, icon_url: $iconUrl, createdAt: $createdAt, latestImageAt: $latestImageAt, invitePermission: $invitePermission, role: $role}';
  }
}
