/// Lightweight reference to an image, just enough to identify it and order it,
/// without the bytes.
class ImageRef {
  /// Which instance holds this photo. Two servers can hand out the same id, and
  /// the bytes only exist on one of them.
  final String instanceId;

  final String id;
  final String? uploadedBy;
  final DateTime? uploadedAt;

  ImageRef({
    required this.instanceId,
    required this.id,
    this.uploadedBy,
    this.uploadedAt,
  });

  factory ImageRef.fromJson(Map<String, dynamic> json,
      {required String instanceId}) {
    return ImageRef(
      instanceId: instanceId,
      id: json['id'].toString(),
      uploadedBy: json['uploaded_by']?.toString(),
      uploadedAt: json['uploaded_at'] != null
          ? DateTime.tryParse(json['uploaded_at'].toString())
          : null,
    );
  }
}
