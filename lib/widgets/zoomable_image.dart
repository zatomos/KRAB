import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A image the user can pinch, pan and double tap.
class ZoomableImage extends StatefulWidget {
  final ImageProvider image;

  /// Called as the image goes past, or comes back to, its fitted size.
  final void Function(bool zoomed)? onZoomChanged;

  final VoidCallback? onTap;

  const ZoomableImage({
    super.key,
    required this.image,
    this.onZoomChanged,
    this.onTap,
  });

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {

  static const Duration _moveDuration = Duration(milliseconds: 200);
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;
  static const double _doubleTapScale = 2.5;
  static const double _zoomedSlop = 1.01;
  static const double _settleSlop = 0.5;
  static const Duration _stillFor = Duration(milliseconds: 32);
  static const double _flingFriction = 1e-30;

  final _view = TransformationController();

  /// The image's pixel size, which fixes the shape of the rect it fills.
  Size? _imageSize;

  /// Where a double tap last landed, in this widget's coordinates.
  Offset? _tappedAt;

  late final AnimationController _mover;
  Matrix4? _moveFrom;
  Matrix4? _moveTo;

  bool _zoomed = false;
  bool _interacting = false;
  Timer? _settleTimer;

  @override
  void initState() {
    super.initState();
    _mover = AnimationController(vsync: this, duration: _moveDuration)
      ..addListener(_onMoveTick);
    _view.addListener(_onViewChanged);
    _measureimage();
  }

  @override
  void didUpdateWidget(ZoomableImage old) {
    super.didUpdateWidget(old);
    if (widget.image != old.image) _measureimage();
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _view.removeListener(_onViewChanged);
    _mover.dispose();
    _view.dispose();
    super.dispose();
  }

  /// Takes the image's size off the decoded image.
  void _measureimage() {
    final stream = widget.image.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final size =
          Size(info.image.width.toDouble(), info.image.height.toDouble());
      if (mounted && size != _imageSize) setState(() => _imageSize = size);
    }, onError: (_, __) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  double get _scale => _view.value.getMaxScaleOnAxis();

  Offset get _offset {
    final t = _view.value.getTranslation();
    return Offset(t.x, t.y);
  }

  Matrix4 _matrixOf(double scale, Offset offset) => Matrix4.identity()
    ..translateByDouble(offset.dx, offset.dy, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1);

  /// The image's rect at scale 1
  Size? get _fittedSize {
    final image = _imageSize;
    final box = context.size;
    if (image == null || box == null || image.isEmpty) return null;
    final scale = math.min(box.width / image.width, box.height / image.height);
    return image * scale;
  }

  Offset? _homeFor(Offset offset, double scale) {
    final fitted = _fittedSize;
    final box = context.size;
    if (fitted == null || box == null) return null;

    final centre = Offset(
      box.width / 2 * scale + offset.dx,
      box.height / 2 * scale + offset.dy,
    );

    double home(double at, double shown, double screen) {
      if (shown < screen) return screen / 2;
      return at.clamp(screen - shown / 2, shown / 2);
    }

    final wanted = Offset(
      home(centre.dx, fitted.width * scale, box.width),
      home(centre.dy, fitted.height * scale, box.height),
    );
    return offset + (wanted - centre);
  }

  void _reportZoom() {
    final zoomed = _scale > _zoomedSlop;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged?.call(zoomed);
  }

  /// Anything that moves the image
  void _onViewChanged() {
    _reportZoom();
    if (_mover.isAnimating) return;
    _settleTimer?.cancel();
    _settleTimer = Timer(_stillFor, _settle);
  }

  /// Eases the image back over the screen.
  void _settle() {
    if (!mounted || _interacting) return;
    final scale = _scale;
    final offset = _offset;
    final home = _homeFor(offset, scale);
    if (home == null || (home - offset).distance < _settleSlop) return;
    _animateTo(_matrixOf(scale, home));
  }

  void _onDoubleTapDown(TapDownDetails details) =>
      _tappedAt = details.localPosition;

  void _onDoubleTap() {
    final box = context.size;
    if (box == null) return;

    final from = _scale;
    final zoomedIn = from > _zoomedSlop;
    final to = zoomedIn ? _minScale : _doubleTapScale;

    final tap = _tappedAt ?? box.center(Offset.zero);
    final onimage = (tap - _offset) / from;
    final offset = tap - onimage * to;

    _animateTo(_matrixOf(to, _homeFor(offset, to) ?? offset));
  }

  void _animateTo(Matrix4 target) {
    _moveFrom = _view.value.clone();
    _moveTo = target;
    _mover.forward(from: 0.0);
  }

  void _onMoveTick() {
    final from = _moveFrom;
    final to = _moveTo;
    if (from == null || to == null) return;
    final t = Curves.easeOutCubic.transform(_mover.value);
    final fromScale = from.getMaxScaleOnAxis();
    final toScale = to.getMaxScaleOnAxis();
    final fromOffset = Offset(from.getTranslation().x, from.getTranslation().y);
    final toOffset = Offset(to.getTranslation().x, to.getTranslation().y);

    _view.value = _matrixOf(
      fromScale + (toScale - fromScale) * t,
      Offset.lerp(fromOffset, toOffset, t)!,
    );
    _reportZoom();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        InteractiveViewer(
          transformationController: _view,
          minScale: _minScale,
          maxScale: _maxScale,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          interactionEndFrictionCoefficient: _flingFriction,
          clipBehavior: Clip.none,
          onInteractionStart: (_) {
            _interacting = true;
            _settleTimer?.cancel();
          },
          onInteractionEnd: (_) {
            _interacting = false;
            _settleTimer?.cancel();
            _settleTimer = Timer(_stillFor, _settle);
          },
          child: Image(
            image: widget.image,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onTap,
            onDoubleTapDown: _onDoubleTapDown,
            onDoubleTap: _onDoubleTap,
          ),
        ),
      ],
    );
  }
}
