import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:krab/services/image_size.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List encode(int width, int height, Uint8List Function(img.Image) as) =>
      as(img.Image(width: width, height: height));

  test('reads the dimensions of a jpeg', () async {
    final bytes = encode(37, 11, (i) => img.encodeJpg(i));
    expect(await readImageSize(bytes), const Size(37, 11));
  });

  test('reads the dimensions of a png', () async {
    final bytes = encode(4, 128, (i) => img.encodePng(i));
    expect(await readImageSize(bytes), const Size(4, 128));
  });

  test('gives back nothing for bytes that are not an image', () async {
    expect(await readImageSize(Uint8List.fromList([1, 2, 3])), Size.zero);
  });
}
