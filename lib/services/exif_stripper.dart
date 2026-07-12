import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Removes metadata from a photo before it leaves the device.
Future<Uint8List> stripImageMetadata(Uint8List bytes) async {
  try {
    return await compute(_stripSync, bytes);
  } catch (e) {
    debugPrint('EXIF strip failed, sending original bytes: $e');
    return bytes;
  }
}

Uint8List _stripSync(Uint8List bytes) {
  final lossless = stripJpegMetadataLossless(bytes);
  if (lossless != null) return lossless;

  // Not a JPEG, we can scrub losslessly. Re-encode
  // as a privacy fallback so metadata is still removed.
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  return img.encodeJpg(img.bakeOrientation(decoded), quality: 100);
}

/// Rewrites a JPEG
Uint8List? stripJpegMetadataLossless(Uint8List bytes) {
  // SOI.
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;

  final out = BytesBuilder(copy: false);
  out.addByte(0xFF);
  out.addByte(0xD8);

  // Header segments we keep, copied verbatim.
  final header = BytesBuilder(copy: false);
  int? orientation; // captured from the first EXIF APP1, if present

  var i = 2;
  while (i < bytes.length) {
    if (bytes[i] != 0xFF) return null; // not aligned on a marker

    // Skip any 0xFF fill bytes preceding the marker code.
    var j = i;
    while (j < bytes.length && bytes[j] == 0xFF) {
      j++;
    }
    if (j >= bytes.length) return null;
    final marker = bytes[j];
    final markerStart = j - 1; // the 0xFF immediately before the marker code
    final afterMarker = j + 1;

    if (marker == 0xD9) return null; // EOI before SOS: unexpected

    // Start of scan: emit the preserved orientation, the kept header segments,
    // then the rest of the file verbatim.
    if (marker == 0xDA) {
      if (orientation != null && orientation != 1) {
        out.add(_minimalExifApp1(orientation));
      }
      out.add(header.toBytes());
      out.add(Uint8List.sublistView(bytes, markerStart));
      return out.toBytes();
    }

    // Every remaining marker carries a 2-byte big-endian length.
    if (afterMarker + 1 >= bytes.length) return null;
    final segLen = (bytes[afterMarker] << 8) | bytes[afterMarker + 1];
    if (segLen < 2) return null;
    final dataStart = afterMarker + 2;
    final segEnd = afterMarker + segLen; // marker length includes its 2 bytes
    if (segEnd > bytes.length) return null;

    final isApp = marker >= 0xE0 && marker <= 0xEF;
    final isCom = marker == 0xFE;

    if (marker == 0xE1) {
      // Possible EXIF APP1; read the orientation before dropping it.
      orientation ??= _readExifOrientation(bytes, dataStart, segEnd);
    }

    if (!isApp && !isCom) {
      header.add(Uint8List.sublistView(bytes, markerStart, segEnd));
    }

    i = segEnd;
  }

  return null; // no SOS found
}

/// Reads the EXIF Orientation from an APP1 payload spanning [start, end),
/// or null if absent/unparseable.
int? _readExifOrientation(Uint8List b, int start, int end) {
  if (end - start < 14) return null;
  // "Exif\0\0"
  if (b[start] != 0x45 ||
      b[start + 1] != 0x78 ||
      b[start + 2] != 0x69 ||
      b[start + 3] != 0x66 ||
      b[start + 4] != 0x00 ||
      b[start + 5] != 0x00) {
    return null;
  }

  final tiff = start + 6;
  final little = b[tiff] == 0x49 && b[tiff + 1] == 0x49;
  final big = b[tiff] == 0x4D && b[tiff + 1] == 0x4D;
  if (!little && !big) return null;

  int u16(int o) =>
      little ? (b[o] | (b[o + 1] << 8)) : ((b[o] << 8) | b[o + 1]);
  int u32(int o) => little
      ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24))
      : ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);

  if (tiff + 8 > end) return null;
  if (u16(tiff + 2) != 0x002A) return null;

  final ifd = tiff + u32(tiff + 4);
  if (ifd + 2 > end) return null;
  final count = u16(ifd);

  for (var k = 0; k < count; k++) {
    final entry = ifd + 2 + k * 12;
    if (entry + 12 > end) return null;
    if (u16(entry) == 0x0112) {
      final value = u16(entry + 8);
      return (value >= 1 && value <= 8) ? value : null;
    }
  }
  return null;
}

/// A minimal big-endian EXIF APP1 segment carrying only the Orientation tag.
Uint8List _minimalExifApp1(int orientation) {
  return Uint8List.fromList([
    0xFF, 0xE1, // APP1 marker
    0x00, 0x22, // length = 34 (2 length bytes + 32-byte payload)
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x4D, 0x4D, // big-endian
    0x00, 0x2A, // TIFF magic
    0x00, 0x00, 0x00, 0x08, // offset to IFD0
    0x00, 0x01, // one IFD entry
    0x01, 0x12, // tag = Orientation
    0x00, 0x03, // type = SHORT
    0x00, 0x00, 0x00, 0x01, // count = 1
    (orientation >> 8) & 0xFF, orientation & 0xFF, 0x00, 0x00, // value
    0x00, 0x00, 0x00, 0x00, // next-IFD offset = 0
  ]);
}
