import 'dart:typed_data';

class ImageData {
  final Uint8List imageBytes;
  final String uploadedBy;

  /// The server where uploadedBy is an account on.
  final String uploaderInstanceId;

  final String createdAt;
  final String? description;

  ImageData({
    required this.imageBytes,
    required this.uploadedBy,
    required this.uploaderInstanceId,
    required this.createdAt,
    this.description,
  });

  @override
  String toString() {
    return 'ImageData{uploadedBy: $uploadedBy@$uploaderInstanceId, '
        'createdAt: $createdAt, description: $description}';
  }
}
