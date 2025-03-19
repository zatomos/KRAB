import 'dart:convert';

class Group {
  final String id;
  final String name;
  final String code;
  final int memberCount;

  Group({
    required this.id,
    required this.name,
    required this.code,
    required this.memberCount,
  });

  // Convert a JSON Map to a Group object
  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      id: json['id'] as String,
      name: json['name'] as String,
      code: json['code'] as String,
      memberCount: json['member_count'] as int,
    );
  }

  // Convert a Group object to a JSON Map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'code': code,
    };
  }

  // Convert a JSON string into a Group object
  static Group fromJsonString(String jsonString) {
    return Group.fromJson(json.decode(jsonString));
  }

  // Convert a Group object into a JSON string
  String toJsonString() {
    return json.encode(toJson());
  }

  @override
  String toString() {
    return 'Group{id: $id, name: $name, code: $code, memberCount: $memberCount}';
  }
}
