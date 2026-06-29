import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Re-encodes the image as a JPEG without embedded metadata.
/// Any EXIF orientation is baked into the pixels first so the photo still
/// shows upright once the orientation tag is gone.
Uint8List? _stripMetadataSync(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  return img.encodeJpg(upright, quality: 90);
}

/// Strips metadata on a background isolate before the photo leaves
/// the device. Falls back to the original bytes if decoding fails.
Future<Uint8List> stripImageMetadata(Uint8List bytes) async {
  try {
    final stripped = await compute(_stripMetadataSync, bytes);
    return stripped ?? bytes;
  } catch (e) {
    debugPrint("EXIF strip failed, sending original bytes: $e");
    return bytes;
  }
}
