import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:krab/widgets/zoomable_image.dart';

class _FakeImage extends ImageProvider<_FakeImage> {
  const _FakeImage();

  @override
  Future<_FakeImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_FakeImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_frame());

  static Future<ImageInfo> _frame() async {
    final recorder = PictureRecorder();
    Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 200, 200), Paint()..color = Colors.red);
    final image = await recorder.endRecording().toImage(200, 200);
    return ImageInfo(image: image);
  }

  @override
  bool operator ==(Object other) => other is _FakeImage;
  @override
  int get hashCode => 0;
}

Matrix4 transformOf(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value;

Offset translationOf(WidgetTester tester) {
  final t = transformOf(tester).getTranslation();
  return Offset(t.x, t.y);
}

Future<void> pumpViewer(WidgetTester tester, {VoidCallback? onTap}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 400,
        child: ZoomableImage(image: const _FakeImage(), onTap: onTap),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Zooms in with a double tap so there is room to pan.
Future<void> zoomIn(WidgetTester tester) async {
  await tester.tap(find.byType(InteractiveViewer));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.byType(InteractiveViewer));
  await tester.pumpAndSettle();
}

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool zoomed = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 400,
      height: 400,
      child: MediaQuery(
        data: MediaQueryData(
          gestureSettings: DeviceGestureSettings(
            touchSlop: zoomed ? kTouchSlop : kPagingTouchSlop,
          ),
        ),
        child: ZoomableImage(
          image: const _FakeImage(),
          onZoomChanged: (value) => setState(() => zoomed = value),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('the first zoom survives the rebuild it triggers',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: _Host())));
    await tester.pumpAndSettle();

    await zoomIn(tester);
    expect(transformOf(tester).getMaxScaleOnAxis(), greaterThan(1.5),
        reason: 'the zoom must outlive the parent rebuild it caused');
  });

  testWidgets('a short drag pans the image', (tester) async {
    await pumpViewer(tester);
    await zoomIn(tester);
    final start = translationOf(tester);

    // Well under the paging slop the viewer page used to impose on its pages.
    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(-10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final moved = translationOf(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moved.dx, lessThan(start.dx));
  });

  testWidgets('double tap zooms in and back out', (tester) async {
    await pumpViewer(tester);
    expect(transformOf(tester).getMaxScaleOnAxis(), 1.0);

    await zoomIn(tester);
    expect(transformOf(tester).getMaxScaleOnAxis(), greaterThan(1.5));

    await zoomIn(tester);
    expect(transformOf(tester).getMaxScaleOnAxis(), 1.0);
  });

  testWidgets('a single tap reports a tap', (tester) async {
    var taps = 0;
    await pumpViewer(tester, onTap: () => taps++);
    await tester.tap(find.byType(InteractiveViewer));
    // The tap is held back until the double tap window closes.
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, 1);
  });

  testWidgets('a pan right after another pan still moves the image',
      (tester) async {
    await pumpViewer(tester);
    await zoomIn(tester);

    Future<void> panOffEdge(TestGesture gesture) async {
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(-100, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    final one = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 16));
    await panOffEdge(one);
    await one.up();
    final afterFirst = translationOf(tester);

    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 60));
    expect(translationOf(tester).dx, greaterThan(afterFirst.dx),
        reason: 'the ease should be under way');
    final easedTo = translationOf(tester);

    final two = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 16));
    await two.moveBy(const Offset(-60, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final duringSecond = translationOf(tester);
    await two.up();
    await tester.pumpAndSettle();

    expect(duringSecond.dx, lessThan(easedTo.dx),
        reason: 'the second pan should move the image, not the ease');
  });
}
