/// Metadata for a single image.
class ImageDetails {
  final String uploadedBy;
  final String createdAt;
  final String? description;

  /// Allows the client to dedupe the image when sent to multiple servers.
  final String? shareId;

  ImageDetails({
    required this.uploadedBy,
    required this.createdAt,
    this.description,
    this.shareId,
  });

  factory ImageDetails.fromJson(Map<String, dynamic> json) {
    return ImageDetails(
      uploadedBy: json['uploaded_by'].toString(),
      createdAt: json['created_at'].toString(),
      description: json['description'] as String?,
      shareId: json['share_id']?.toString(),
    );
  }
}
