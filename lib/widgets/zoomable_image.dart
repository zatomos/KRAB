import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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
  static const double _flingFriction = 1e-10;

  final _view = TransformationController();

  /// The image's pixel size, which fixes the shape of the rect it fills.
  Size? _imageSize;

  late final AnimationController _mover;
  Matrix4? _moveFrom;
  Matrix4? _moveTo;

  bool _zoomed = false;
  bool _interacting = false;
  Timer? _settleTimer;
  int _pointers = 0;
  Offset? _downAt;
  bool _stillATap = false;
  Offset? _firstTapAt;
  Timer? _tapTimer;

  @override
  void initState() {
    super.initState();
    _mover = AnimationController(vsync: this, duration: _moveDuration)
      ..addListener(_onMoveTick);
    _view.addListener(_onViewChanged);
    _measureImage();
  }

  @override
  void didUpdateWidget(ZoomableImage old) {
    super.didUpdateWidget(old);
    if (widget.image != old.image) _measureImage();
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _tapTimer?.cancel();
    _view.removeListener(_onViewChanged);
    _mover.dispose();
    _view.dispose();
    super.dispose();
  }

  /// Takes the image's size off the decoded image.
  void _measureImage() {
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
    if (!mounted || _interacting || _mover.isAnimating) return;
    final scale = _scale;
    final offset = _offset;
    final home = _homeFor(offset, scale);
    if (home == null || (home - offset).distance < _settleSlop) return;
    _animateTo(_matrixOf(scale, home));
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers++;
    _interacting = true;
    _settleTimer?.cancel();
    _stopMove();
    if (_pointers > 1) {
      _stillATap = false;
      return;
    }
    _downAt = event.localPosition;
    _stillATap = true;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final down = _downAt;
    if (!_stillATap || down == null) return;
    if ((event.localPosition - down).distance > kTouchSlop) _stillATap = false;
  }

  void _onPointerDone({required bool cancelled}) {
    _pointers = math.max(0, _pointers - 1);
    if (cancelled) _stillATap = false;
    if (_pointers > 0) return;

    _interacting = false;
    _settleTimer?.cancel();
    _settleTimer = Timer(_stillFor, _settle);
    _endTap();
    _stillATap = false;
  }

  /// Folds a finished interaction into a tap, a double tap, or neither.
  void _endTap() {
    final at = _downAt;
    if (!_stillATap || at == null) {
      _firstTapAt = null;
      _tapTimer?.cancel();
      return;
    }

    final first = _firstTapAt;
    if (first != null && (at - first).distance <= kDoubleTapSlop) {
      _tapTimer?.cancel();
      _firstTapAt = null;
      _onDoubleTap(at);
      return;
    }

    _firstTapAt = at;
    _tapTimer?.cancel();
    _tapTimer = Timer(kDoubleTapTimeout, () {
      _firstTapAt = null;
      if (mounted) widget.onTap?.call();
    });
  }

  /// Zooms to tap, or back out if already zoomed in.
  void _onDoubleTap(Offset tap) {
    final box = context.size;
    if (box == null) return;

    final from = _scale;
    final zoomedIn = from > _zoomedSlop;
    final to = zoomedIn ? _minScale : _doubleTapScale;

    final onImage = (tap - _offset) / from;
    final offset = tap - onImage * to;

    _animateTo(_matrixOf(to, _homeFor(offset, to) ?? offset));
  }

  void _animateTo(Matrix4 target) {
    _moveFrom = _view.value.clone();
    _moveTo = target;
    _mover.forward(from: 0.0);
  }

  void _stopMove() {
    if (!_mover.isAnimating) return;
    _mover.stop();
    _moveFrom = null;
    _moveTo = null;
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
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _onPointerDone(cancelled: false),
      onPointerCancel: (_) => _onPointerDone(cancelled: true),
      child: InteractiveViewer(
        transformationController: _view,
        minScale: _minScale,
        maxScale: _maxScale,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        interactionEndFrictionCoefficient: _flingFriction,
        clipBehavior: Clip.none,
        child: Image(
          image: widget.image,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}
