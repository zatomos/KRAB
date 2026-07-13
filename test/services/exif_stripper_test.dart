import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:krab/services/exif_stripper.dart';

// JPEG marker bytes.
const _ff = 0xFF;
const _soi = 0xD8;
const _app0 = 0xE0;
const _app1 = 0xE1;
const _dqt = 0xDB;
const _sos = 0xDA;
const _eoi = 0xD9;

/// A segment: FF <marker> <2-byte length> <payload>. Length includes itself.
List<int> _segment(int marker, List<int> payload) {
  final len = payload.length + 2;
  return [_ff, marker, (len >> 8) & 0xFF, len & 0xFF, ...payload];
}

/// A big-endian EXIF APP1 payload with an Orientation tag plus a second
/// (GPS-ish) tag that must be stripped.
List<int> _exifPayload(int orientation) => [
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
      0x4D, 0x4D, // big-endian
      0x00, 0x2A, // TIFF magic
      0x00, 0x00, 0x00, 0x08, // IFD0 offset
      0x00, 0x02, // two entries
      // Orientation (0x0112), SHORT, value = orientation
      0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01,
      (orientation >> 8) & 0xFF, orientation & 0xFF, 0x00, 0x00,
      // GPS IFD pointer (0x8825) — sensitive metadata that must disappear
      0x88, 0x25, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF,
      0x00, 0x00, 0x00, 0x00, // next IFD offset
    ];

/// The unique bytes of the entropy-coded scan, which must survive untouched.
final _scanTail = <int>[0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC];

Uint8List _buildJpeg({required int orientation}) {
  return Uint8List.fromList([
    _ff, _soi,
    ..._segment(_app1, _exifPayload(orientation)),
    ..._segment(_app0, [0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01]), // JFIF
    ..._segment(_dqt, [0x00, 0xAA, 0xBB, 0xCC]), // quant table (must survive)
    ..._segment(_sos, [0x01, 0x02]), // start of scan header
    ..._scanTail, // entropy data
    _ff, _eoi,
  ]);
}

/// A real JPEG of [width]x[height], carrying a GPS tag that must not survive.
Uint8List _realJpeg({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  // Some actual variation, so a quality drop has something to lose.
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, x % 256, y % 256, (x * y) % 256);
    }
  }
  image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(48, 1);
  return img.encodeJpg(image, quality: 100);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stripImageMetadata', () {
    test('leaves a JPEG at full resolution by default', () async {
      final out = await stripImageMetadata(_realJpeg(width: 400, height: 200));

      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 400);
      expect(decoded.height, 200);
    });

    test('caps the longest edge of a landscape photo', () async {
      final out = await stripImageMetadata(
        _realJpeg(width: 400, height: 200),
        maxDimension: 100,
      );

      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 100);
      expect(decoded.height, 50, reason: 'aspect ratio must be preserved');
    });

    test('caps the longest edge of a portrait photo', () async {
      final out = await stripImageMetadata(
        _realJpeg(width: 200, height: 400),
        maxDimension: 100,
      );

      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 50);
      expect(decoded.height, 100);
    });

    test('does not upscale a photo smaller than the cap', () async {
      final out = await stripImageMetadata(
        _realJpeg(width: 80, height: 40),
        maxDimension: 1000,
      );

      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 80);
      expect(decoded.height, 40);
    });

    test('a lower quality produces a smaller file', () async {
      final src = _realJpeg(width: 400, height: 200);
      final full = await stripImageMetadata(src);
      final lossy = await stripImageMetadata(src, quality: 50);

      expect(lossy.length, lessThan(full.length));
    });

    test('drops EXIF on the re-encode path', () async {
      final out = await stripImageMetadata(
        _realJpeg(width: 400, height: 200),
        maxDimension: 100,
      );

      expect(img.decodeJpg(out)!.exif.gpsIfd.isEmpty, isTrue);
    });
  });

  group('stripJpegMetadataLossless', () {
    test('returns null for non-JPEG input', () {
      expect(stripJpegMetadataLossless(Uint8List.fromList([1, 2, 3])), isNull);
      expect(stripJpegMetadataLossless(Uint8List(0)), isNull);
    });

    test('drops APP0/APP1 metadata segments', () {
      final out = stripJpegMetadataLossless(_buildJpeg(orientation: 6))!;

      // The JFIF APP0 marker and the GPS bytes must be gone.
      expect(_contains(out, [0x4A, 0x46, 0x49, 0x46]), isFalse,
          reason: 'JFIF APP0 should be stripped');
      expect(_contains(out, [0xDE, 0xAD, 0xBE, 0xEF]), isFalse,
          reason: 'GPS metadata should be stripped');
    });

    test('preserves the quant table and scan data byte-for-byte', () {
      final out = stripJpegMetadataLossless(_buildJpeg(orientation: 1))!;

      // DQT segment kept.
      expect(_contains(out, [_ff, _dqt, 0x00, 0x06, 0x00, 0xAA, 0xBB, 0xCC]),
          isTrue);
      // Scan tail kept, ending in EOI.
      expect(_contains(out, [..._scanTail, _ff, _eoi]), isTrue);
    });

    test('re-emits a minimal EXIF with the original orientation', () {
      final out = stripJpegMetadataLossless(_buildJpeg(orientation: 6))!;

      // The minimal APP1 block: FF E1 00 22 "Exif\0\0" ... orientation value.
      expect(
        _contains(out, [
          _ff, _app1, 0x00, 0x22, //
          0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
        ]),
        isTrue,
      );
      // Orientation value 6 present in the emitted block.
      expect(_contains(out, [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06]),
          isTrue);
    });

    test('omits the EXIF block entirely when orientation is normal (1)', () {
      final out = stripJpegMetadataLossless(_buildJpeg(orientation: 1))!;
      // No APP1 marker at all.
      expect(_contains(out, [_ff, _app1]), isFalse);
    });

    test('is smaller than the original (metadata removed)', () {
      final src = _buildJpeg(orientation: 6);
      final out = stripJpegMetadataLossless(src)!;
      expect(out.length, lessThan(src.length));
    });
  });
}

/// Whether [haystack] contains [needle] as a contiguous subsequence.
bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
