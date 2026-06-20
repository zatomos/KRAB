/// Lightweight reference to an image, just enough to identify it and order it,
/// without the bytes.
class ImageRef {
  final String id;
  final String? uploadedBy;
  final DateTime? uploadedAt;

  ImageRef({required this.id, this.uploadedBy, this.uploadedAt});

  factory ImageRef.fromJson(Map<String, dynamic> json) {
    return ImageRef(
      id: json['id'].toString(),
      uploadedBy: json['uploaded_by']?.toString(),
      uploadedAt: json['uploaded_at'] != null
          ? DateTime.tryParse(json['uploaded_at'].toString())
          : null,
    );
  }
}
