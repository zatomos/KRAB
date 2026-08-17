import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:krab/services/blur_worker.dart';

Uint8List _image({int width = 400, int height = 300}) {
  final image = img.Image(width: width, height: height);
  img.fillRect(image, x1: 0, y1: 0, x2: width ~/ 2, y2: height,
      color: img.ColorRgb8(255, 0, 0));
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  final worker = BlurWorker.instance;
  tearDown(worker.stop);

  test('blurs an image down to backdrop size', () async {
    final blurred = await worker.blur(_image());

    expect(blurred, isNotNull);
    final decoded = img.decodeImage(blurred!);
    expect(decoded?.width, 128);
  });

  test('keeps one worker up across jobs instead of one per image', () async {
    await worker.blur(_image());
    expect(worker.isRunning, isTrue);

    // Several at once are handed to that same worker
    final all = await Future.wait([
      worker.blur(_image(width: 200, height: 200)),
      worker.blur(_image(width: 640, height: 480)),
      worker.blur(_image()),
    ]);
    expect(all, everyElement(isNotNull));
    expect(worker.isRunning, isTrue);
  });

  test('gives back nothing for bytes that are not an image', () async {
    expect(await worker.blur(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('starts again after being stopped', () async {
    await worker.blur(_image());
    worker.stop();
    expect(worker.isRunning, isFalse);

    expect(await worker.blur(_image()), isNotNull);
    expect(worker.isRunning, isTrue);
  });

  test('stopping mid-job answers null rather than hanging', () async {
    final inFlight = worker.blur(_image(width: 2000, height: 2000));
    worker.stop();

    expect(await inFlight, isNull);
  });
}
