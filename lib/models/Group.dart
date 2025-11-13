import 'dart:convert';

class Group {
  final String id;
  final String name;
  final String? code;
  final String? iconUrl;
  final String createdAt;

  Group({
    required this.id,
    required this.name,
    this.code,
    this.iconUrl,
    required this.createdAt,
  });

  // Convert a JSON Map to a Group object
  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      id: json['id'] as String,
      name: json['name'] as String,
      code: json['code'] as String?,
      iconUrl: json['icon_url'] as String?,
      createdAt: json['created_at'] as String,
    );
  }

  Group copyWith({
    String? id,
    String? name,
    String? code,
    String? iconUrl,
    String? createdAt,
  }) {
    return Group(
      id: id ?? this.id,
      name: name ?? this.name,
      code: code ?? this.code,
      iconUrl: iconUrl ?? this.iconUrl,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  // Convert a Group object to a JSON Map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'code': code,
      'icon_url': iconUrl,
      'created_at': createdAt,
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
    return 'Group{id: $id, name: $name, code: $code, icon_url: $iconUrl, createdAt: $createdAt}';
  }
}
