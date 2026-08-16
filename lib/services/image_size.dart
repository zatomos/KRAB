import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Reads an encoded image's pixel dimensions from its header without decoding
Future<Size> readImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } catch (err) {
    debugPrint("Could not read image size ($err)");
    return Size.zero;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
