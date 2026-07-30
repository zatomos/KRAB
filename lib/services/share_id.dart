import 'dart:math';

final Random _random = Random.secure();

/// A fresh id tying together every copy of one image, however many servers end
/// up holding it.
String newShareId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));

  // Version 4, variant 1, per RFC 4122.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String hex(int start, int end) => [
        for (var i = start; i < end; i++)
          bytes[i].toRadixString(16).padLeft(2, '0')
      ].join();

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
