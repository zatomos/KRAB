class GroupInvite {
  final String token;
  final String createdBy;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final int? maxUses;
  final int uses;
  final bool revoked;

  GroupInvite({
    required this.token,
    required this.createdBy,
    required this.createdAt,
    this.expiresAt,
    this.maxUses,
    required this.uses,
    required this.revoked,
  });

  factory GroupInvite.fromJson(Map<String, dynamic> json) {
    return GroupInvite(
      token: json['token'] as String,
      createdBy: json['created_by'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      expiresAt: json['expires_at'] != null
          ? DateTime.parse(json['expires_at'] as String)
          : null,
      maxUses: json['max_uses'] as int?,
      uses: (json['uses'] as num).toInt(),
      revoked: json['revoked'] as bool,
    );
  }

  /// An invite is usable if it hasn't been revoked, hasn't expired, and still
  /// has uses left.
  bool get isActive {
    if (revoked) return false;
    if (expiresAt != null && expiresAt!.isBefore(DateTime.now())) return false;
    if (maxUses != null && uses >= maxUses!) return false;
    return true;
  }
}
