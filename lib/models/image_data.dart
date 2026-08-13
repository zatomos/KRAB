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

  /// The same image with an updated description. An empty one reads as none.
  ImageData withDescription(String description) => ImageData(
        imageBytes: imageBytes,
        uploadedBy: uploadedBy,
        uploaderInstanceId: uploaderInstanceId,
        createdAt: createdAt,
        description: description.isEmpty ? null : description,
      );

  @override
  String toString() {
    return 'ImageData{uploadedBy: $uploadedBy@$uploaderInstanceId, '
        'createdAt: $createdAt, description: $description}';
  }
}
