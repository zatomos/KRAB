import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/services/image_size.dart';

/// One photo in the viewer's pager.
class ViewerPhoto extends StatefulWidget {
  final Size displaySize;
  final String? heroTag;
  final Uint8List? initialBytes;
  final Future<ImageData> imageDataFuture;
  final Future<Uint8List?> fullFuture;
  final void Function(Uint8List lowBytes) onLowBytes;
  final void Function(Size naturalSize) onNaturalSize;
  final void Function(bool zoomed) onZoomChanged;

  /// Where the viewer's decoded photos are held.
  final String imageCacheName;

  /// False while the hero is flying
  final bool settled;

  const ViewerPhoto({
    super.key,
    required this.displaySize,
    required this.heroTag,
    required this.initialBytes,
    required this.imageDataFuture,
    required this.fullFuture,
    required this.onLowBytes,
    required this.onNaturalSize,
    required this.onZoomChanged,
    required this.imageCacheName,
    required this.settled,
  });

  @override
  State<ViewerPhoto> createState() => _ViewerPhotoState();
}

class _ViewerPhotoState extends State<ViewerPhoto>
    with SingleTickerProviderStateMixin {
  static const Duration _fadeInDuration = Duration(milliseconds: 250);
  static const double _doubleTapScale = 2.5;

  Uint8List? _low;
  Uint8List? _full;

  /// Whether the natural size has been read off the thumbnail
  bool _haveNaturalSize = false;

  late final AnimationController _doubleTapController;
  Animation<double>? _doubleTapAnimation;
  VoidCallback? _doubleTapListener;

  @override
  void initState() {
    super.initState();
    _doubleTapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _low = widget.initialBytes;
    if (_low != null) {
      widget.onLowBytes(_low!);
      _resolveNaturalSize(_low!);
    } else {
      _loadLow();
    }
    _loadFull();
  }

  @override
  void dispose() {
    if (_doubleTapListener != null) {
      _doubleTapAnimation?.removeListener(_doubleTapListener!);
    }
    _doubleTapController.dispose();
    super.dispose();
  }

  Future<void> _loadLow() async {
    final data = await widget.imageDataFuture;
    if (!mounted) return;
    setState(() => _low = data.imageBytes);
    widget.onLowBytes(data.imageBytes);
    _resolveNaturalSize(data.imageBytes);
  }

  void _resolveNaturalSize(Uint8List bytes) {
    readImageSize(bytes).then((size) {
      if (!mounted || size.isEmpty) return;
      _haveNaturalSize = true;
      widget.onNaturalSize(size);
    });
  }

  Future<void> _loadFull() async {
    final full = await widget.fullFuture;
    if (!mounted || full == null) return;
    await precacheImage(
      ExtendedMemoryImageProvider(full, imageCacheName: widget.imageCacheName),
      context,
    );
    if (!mounted) return;
    setState(() => _full = full);
    if (!_haveNaturalSize) _resolveNaturalSize(full);
  }

  GestureConfig _initGestureConfig(ExtendedImageState state) => GestureConfig(
        inPageView: true,
        initialScale: 1.0,
        minScale: 1.0,
        animationMinScale: 1.0,
        maxScale: 5.0,
        animationMaxScale: 6.0,
        cacheGesture: false,
        gestureDetailsIsChanged: (details) {
          if (details == null) return;
          widget.onZoomChanged((details.totalScale ?? 1.0) > 1.01);
        },
      );

  /// Animates a double-tap zoom toward the tapped point
  void _onDoubleTap(ExtendedImageGestureState state) {
    final pointer = state.pointerDownPosition;
    final begin = state.gestureDetails?.totalScale ?? 1.0;
    final end = begin <= 1.01 ? _doubleTapScale : 1.0;

    if (_doubleTapListener != null) {
      _doubleTapAnimation?.removeListener(_doubleTapListener!);
    }
    _doubleTapController.stop();
    _doubleTapController.value = 0.0;
    _doubleTapAnimation = Tween<double>(begin: begin, end: end).animate(
      CurvedAnimation(parent: _doubleTapController, curve: Curves.easeOutCubic),
    );
    _doubleTapListener = () => state.handleDoubleTap(
          scale: _doubleTapAnimation!.value,
          doubleTapPosition: pointer,
        );
    _doubleTapAnimation!.addListener(_doubleTapListener!);
    _doubleTapController.forward();
  }

  Widget _buildHeroFlight(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    // Fly the low-res bytes
    final bytes = _low;
    if (bytes == null) return const SizedBox.shrink();
    return Image.memory(
      bytes,
      fit: direction == HeroFlightDirection.pop
          ? BoxFit.cover // back into the grid's square tile
          : BoxFit.contain, // out to the viewer's contained rect
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  Widget build(BuildContext context) {
    final low = _low;
    if (low == null) return const SizedBox.expand();

    // Low-res base
    Widget base = Image.memory(
      low,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
    if (widget.heroTag != null) {
      base = Hero(
        tag: widget.heroTag!,
        flightShuttleBuilder: _buildHeroFlight,
        child: base,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: SizedBox.fromSize(size: widget.displaySize, child: base),
        ),
        AnimatedOpacity(
          opacity: widget.settled ? 1.0 : 0.0,
          duration: widget.settled ? _fadeInDuration : Duration.zero,
          curve: Curves.easeOut,
          child: ExtendedImage.memory(
            _full ?? low,
            imageCacheName: widget.imageCacheName,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            mode: ExtendedImageMode.gesture,
            onDoubleTap: _onDoubleTap,
            initGestureConfigHandler: _initGestureConfig,
          ),
        ),
      ],
    );
  }
}
