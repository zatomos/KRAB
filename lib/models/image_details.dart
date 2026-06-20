/// Metadata for a single image.
class ImageDetails {
  final String uploadedBy;
  final String createdAt;
  final String? description;

  ImageDetails({
    required this.uploadedBy,
    required this.createdAt,
    this.description,
  });

  factory ImageDetails.fromJson(Map<String, dynamic> json) {
    return ImageDetails(
      uploadedBy: json['uploaded_by'].toString(),
      createdAt: json['created_at'].toString(),
      description: json['description'] as String?,
    );
  }
}
