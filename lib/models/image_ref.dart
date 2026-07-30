/// Lightweight reference to an image, just enough to identify it and order it,
/// without the bytes.
class ImageRef {
  /// Which instance holds this image. Two servers can hand out the same id, and
  /// the bytes only exist on one of them.
  final String instanceId;

  final String id;

  /// Minted by the uploader when the image was sent, and identical on every
  /// copy of it.
  final String? shareId;

  final String? uploadedBy;
  final DateTime? uploadedAt;

  ImageRef({
    required this.instanceId,
    required this.id,
    this.shareId,
    this.uploadedBy,
    this.uploadedAt,
  });

  String get identity => shareId ?? '$instanceId/$id';

  factory ImageRef.fromJson(Map<String, dynamic> json,
      {required String instanceId, String? shareId}) {
    return ImageRef(
      instanceId: instanceId,
      id: json['id'].toString(),
      shareId: shareId ?? json['share_id']?.toString(),
      uploadedBy: json['uploaded_by']?.toString(),
      uploadedAt: json['uploaded_at'] != null
          ? DateTime.tryParse(json['uploaded_at'].toString())
          : null,
    );
  }

  ImageRef copyWith({String? shareId}) => ImageRef(
        instanceId: instanceId,
        id: id,
        shareId: shareId ?? this.shareId,
        uploadedBy: uploadedBy,
        uploadedAt: uploadedAt,
      );

  @override
  String toString() =>
      'ImageRef{instanceId: $instanceId, id: $id, shareId: $shareId}';
}
