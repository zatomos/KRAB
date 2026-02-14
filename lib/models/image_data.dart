import 'dart:convert';
import 'dart:typed_data';


class ImageData {
  final Uint8List imageBytes;
  final String uploadedBy;
  final String createdAt;
  final String? description;

  ImageData({
    required this.imageBytes,
    required this.uploadedBy,
    required this.createdAt,
    this.description,
  });

  factory ImageData.fromJson(Map<String, dynamic> json) {
    return ImageData(
      imageBytes: base64Decode(json['image_bytes']),
      uploadedBy: json['uploaded_by'],
      createdAt: json['created_at'],
      description: json['description'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'image_bytes': base64Encode(imageBytes),
      'uploaded_by': uploadedBy,
      'created_at': createdAt,
      'description': description,
    };
  }

  static ImageData fromJsonString(String jsonString) {
    return ImageData.fromJson(json.decode(jsonString));
  }

  String toJsonString() {
    return json.encode(toJson());
  }

  @override
  String toString() {
    return 'ImageData{uploadedBy: $uploadedBy, createdAt: $createdAt, description: $description}';
  }
}