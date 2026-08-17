import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/services/image_size.dart';
import 'package:krab/widgets/zoomable_image.dart';

class ViewerImage extends StatefulWidget {
  final Size displaySize;
  final String? heroTag;
  final Uint8List? initialBytes;
  final Future<ImageData> imageDataFuture;
  final Future<Uint8List?> fullFuture;
  final void Function(Uint8List lowBytes) onLowBytes;
  final void Function(Size naturalSize) onNaturalSize;
  final void Function(bool zoomed) onZoomChanged;
  final VoidCallback onTap;

  /// Where the viewer's decoded images are held.
  final String imageCacheName;

  /// False while the hero is flying
  final bool settled;

  const ViewerImage({
    super.key,
    required this.displaySize,
    required this.heroTag,
    required this.initialBytes,
    required this.imageDataFuture,
    required this.fullFuture,
    required this.onLowBytes,
    required this.onNaturalSize,
    required this.onZoomChanged,
    required this.onTap,
    required this.imageCacheName,
    required this.settled,
  });

  @override
  State<ViewerImage> createState() => _ViewerImageState();
}

class _ViewerImageState extends State<ViewerImage> {
  static const Duration _fadeInDuration = Duration(milliseconds: 250);

  late bool _handedOver = widget.settled;

  Uint8List? _low;
  Uint8List? _full;

  /// Whether the pixel size has been read off the thumbnail already.
  bool _haveNaturalSize = false;

  @override
  void initState() {
    super.initState();
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
  void didUpdateWidget(ViewerImage old) {
    super.didUpdateWidget(old);
    if (!widget.settled && _handedOver) _handedOver = false;
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
    await precacheImage(_providerFor(full), context);
    if (!mounted) return;
    setState(() => _full = full);
    if (!_haveNaturalSize) _resolveNaturalSize(full);
  }

  ImageProvider _providerFor(Uint8List bytes) =>
      ExtendedMemoryImageProvider(bytes, imageCacheName: widget.imageCacheName);

  /// The image that actually flies between the grid and the viewer.
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
        Opacity(
          opacity: _handedOver ? 0.0 : 1.0,
          child: Center(
            child: SizedBox.fromSize(size: widget.displaySize, child: base),
          ),
        ),
        AnimatedOpacity(
          opacity: widget.settled ? 1.0 : 0.0,
          duration: widget.settled ? _fadeInDuration : Duration.zero,
          curve: Curves.easeOut,
          onEnd: () {
            if (widget.settled && !_handedOver) {
              setState(() => _handedOver = true);
            }
          },
          child: ZoomableImage(
            image: _providerFor(_full ?? low),
            onZoomChanged: widget.onZoomChanged,
            onTap: widget.onTap,
          ),
        ),
      ],
    );
  }
}
