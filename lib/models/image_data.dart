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

  @override
  String toString() {
    return 'ImageData{uploadedBy: $uploadedBy, createdAt: $createdAt, description: $description}';
  }
}
