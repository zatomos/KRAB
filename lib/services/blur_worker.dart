import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Downscales and gaussian-blurs an image for the gallery backdrop.
Uint8List? _createBlurredBackgroundBytes(Uint8List sourceBytes) {
  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) return null;

  final resized = img.copyResize(
    decoded,
    width: 128,
    interpolation: img.Interpolation.average,
  );
  final blurred = img.gaussianBlur(resized, radius: 16);
  return Uint8List.fromList(img.encodeJpg(blurred, quality: 75));
}

/// Runs the gallery's backdrop blurs on one isolate.
class BlurWorker {
  BlurWorker._();

  /// The worker every viewer shares.
  static final BlurWorker instance = BlurWorker._();

  Isolate? _isolate;
  ReceivePort? _responses;
  Future<SendPort?>? _starting;
  int _generation = 0;
  int _nextId = 0;
  final Map<int, Completer<Uint8List?>> _pending = {};

  /// Whether a worker is up right now.
  @visibleForTesting
  bool get isRunning => _isolate != null;

  /// A blurred backdrop, or null if the worker couldn't make one.
  Future<Uint8List?> blur(Uint8List bytes) async {
    final generation = _generation;
    final requests = await (_starting ??= _start());
    if (requests == null || generation != _generation) return null;

    final id = _nextId++;
    final answer = Completer<Uint8List?>();
    _pending[id] = answer;
    requests.send((id, bytes));
    return answer.future;
  }

  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _forget();
  }

  Future<SendPort?> _start() async {
    final generation = _generation;
    final responses = ReceivePort();
    final ready = Completer<SendPort>();

    responses.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is (int, Uint8List?)) {
        final (id, blurred) = message;
        _pending.remove(id)?.complete(blurred);
      } else {
        _forget();
      }
    });

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _blurIsolate,
        responses.sendPort,
        onExit: responses.sendPort,
        debugName: 'krab_blur',
      );
    } catch (err) {
      debugPrint("Blur worker could not start ($err)");
      responses.close();
      _starting = null;
      return null;
    }

    // Stopped while it was still coming up
    if (generation != _generation) {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      return null;
    }

    _isolate = isolate;
    _responses = responses;
    return ready.future;
  }

  /// Drops every trace of the worker.
  void _forget() {
    _isolate = null;
    _responses?.close();
    _responses = null;
    _starting = null;
    _generation++;
    for (final answer in _pending.values) {
      if (!answer.isCompleted) answer.complete(null);
    }
    _pending.clear();
  }
}

void _blurIsolate(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((message) {
    final (id, bytes) = message as (int, Uint8List);
    Uint8List? blurred;
    try {
      blurred = _createBlurredBackgroundBytes(bytes);
    } catch (err) {
      debugPrint("Blur worker failed on one image ($err)");
    }
    responses.send((id, blurred));
  });
}
