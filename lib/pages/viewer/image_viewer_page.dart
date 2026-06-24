import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/image_data.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/pages/viewer/viewer_overlay.dart';

/// Resolves the pixel dimensions of encoded image. Used to give the
/// viewer a stable child size before the hero flight starts, so the entry
/// image flies to its exact on-screen rect without a mid-flight resize.
Future<Size> decodeImageSize(Uint8List bytes) {
  final completer = Completer<Size>();
  final stream = MemoryImage(bytes).resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) {
        completer.complete(
          Size(info.image.width.toDouble(), info.image.height.toDouble()),
        );
      }
    },
    onError: (_, __) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete(const Size(1, 1));
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Double-tap toggles between fitted and the image's true pixel size
PhotoViewScaleState _doubleTapZoomCycle(PhotoViewScaleState actual) {
  switch (actual) {
    case PhotoViewScaleState.initial:
    case PhotoViewScaleState.zoomedOut:
      return PhotoViewScaleState.originalSize;
    default:
      return PhotoViewScaleState.initial;
  }
}

/// Downscales and blurs an image off the main isolate for the gallery backdrop
Uint8List? createBlurredBackgroundBytes(Uint8List sourceBytes) {
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

/// Full-screen, swipeable viewer for a feed of images with a blurred backdrop.
/// Opened from [ImageFeedPage], which owns the image list and caches.
class ImageViewerPage extends StatefulWidget {
  final List<ImageRef> images;
  final int initialIndex;
  final ImageData initialImageData;
  final krab_user.User initialUploader;

  /// Natural pixel size of the entry image
  final Size? initialImageSize;

  /// The group being viewed, or null for the cross-group recent photos gallery.
  final String? groupId;
  final Future<ImageData> Function(String) getImageData;
  final Future<Uint8List?> Function(String) getOrStartFullResFuture;
  final Future<Uint8List?> Function(String, {bool lowRes}) getCachedImage;
  final Map<String, int> commentCountCache;
  final Map<String, krab_user.User> userCache;
  final void Function(String imageId, int delta)? onCommentCountChanged;

  /// Loads the next page of images when the user swipes near the end, and
  /// reports whether more remain. images grows in place as pages load.
  /// Null disables pagination.
  final Future<void> Function()? loadMore;
  final bool Function()? hasMore;

  const ImageViewerPage({
    super.key,
    required this.images,
    required this.initialIndex,
    required this.initialImageData,
    required this.initialUploader,
    this.initialImageSize,
    required this.groupId,
    required this.getImageData,
    required this.getOrStartFullResFuture,
    required this.getCachedImage,
    required this.commentCountCache,
    required this.userCache,
    this.onCommentCountChanged,
    this.loadMore,
    this.hasMore,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late int _currentIndex;
  // The page nearest screen-center. Only this page carries a Hero, so popping
  // mid-swipe flies a single image, not both.
  late int _heroIndex;

  // Bytes cached here as pages load so the background never needs an async
  // lookup, keyed by page index.
  final Map<int, Uint8List> _pageBytes = {};
  // Natural image size per page, used as PhotoView's child size so contained/
  // covered/original scales differ (enabling double-tap zoom) and panning
  // clamps to the image. Resolved lazily, except the entry page which is
  // seeded up front to keep its hero flight stable.
  final Map<int, Size> _childSizes = {};

  // The overlay chrome fades in once the hero flight settles, so it doesn't
  // flicker as the flying image passes over and behind it
  late final AnimationController _controlsAnim;

  // Whether the current page is zoomed past its fitted size, which gates the
  // swipe-up-to-comments gesture in the overlay
  bool _isZoomed = false;

  // Start fetching the next page once within this many images of the end
  static const int _loadMoreThreshold = 3;
  bool _isLoadingMore = false;

  // Cap on how many pages' bytes/sizes/futures are retained. Tracks access
  // order and evicts the least-recently-used page once over ,the cap,
  // never touching the pages currently in use.
  static const int _maxCachedPages = 7;
  final List<int> _lru = [];

  static const double _doubleTapZoom = 2.0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _heroIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(_onScroll);
    _pageBytes[widget.initialIndex] = widget.initialImageData.imageBytes;
    if (widget.initialImageSize != null) {
      _childSizes[widget.initialIndex] = widget.initialImageSize!;
    }
    _touch(widget.initialIndex);

    _controlsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _controlsAnim.forward();
      });
    });

    // The entry image may already sit near the end of the loaded set
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeLoadMore();
      _prefetchNeighbors(widget.initialIndex);
    });
  }

  @override
  void dispose() {
    _pageController.removeListener(_onScroll);
    _pageController.dispose();
    _controlsAnim.dispose();
    super.dispose();
  }

  /// Keep the Hero attached to whichever page is nearest screen-center, so a
  /// pop while mid-swipe flies only that single image.
  void _onScroll() {
    final page = _pageController.page;
    if (page == null) return;
    final nearest = page.round().clamp(0, widget.images.length - 1);
    if (nearest != _heroIndex) setState(() => _heroIndex = nearest);
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      // A freshly settled page always starts fitted to the screen
      _isZoomed = false;
    });
    _maybeLoadMore();
    _prefetchNeighbors(index);
    _evictDistantPages();
  }

  /// Warm the low-res bytes of the adjacent pages so swiping onto them shows
  /// the image immediately and the blurred background for the new page
  /// is already cached when it becomes current.
  void _prefetchNeighbors(int index) {
    for (final i in [index - 1, index + 1]) {
      if (i < 0 || i >= widget.images.length) continue;
      if (_pageBytes.containsKey(i)) continue;
      _imageDataFor(i).then((data) {
        if (mounted) _cachePageBytes(i, data.imageBytes);
      });
    }
  }

  void _onScaleStateChanged(PhotoViewScaleState state) {
    final zoomed = state != PhotoViewScaleState.initial &&
        state != PhotoViewScaleState.zoomedOut;
    if (zoomed != _isZoomed) setState(() => _isZoomed = zoomed);
  }

  /// Pull in the next page when the user nears the end of the loaded images
  Future<void> _maybeLoadMore() async {
    if (_isLoadingMore || widget.loadMore == null) return;
    if (!(widget.hasMore?.call() ?? false)) return;
    if (_currentIndex < widget.images.length - _loadMoreThreshold) return;

    _isLoadingMore = true;
    await widget.loadMore!();
    if (!mounted) return;
    // Rebuild so the gallery picks up the newly appended images.
    setState(() => _isLoadingMore = false);
  }

  void _cachePageBytes(int index, Uint8List bytes) {
    if (_pageBytes.containsKey(index)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_pageBytes.containsKey(index)) {
        setState(() => _pageBytes[index] = bytes);
        _touch(index);
      }
    });
  }

  void _setChildSize(int index, Size size) {
    if (_childSizes[index] == size) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _childSizes[index] != size) {
        setState(() => _childSizes[index] = size);
        _touch(index);
      }
    });
  }

  /// Mark index as most-recently used in the page cache.
  void _touch(int index) {
    _lru.remove(index);
    _lru.add(index);
  }

  /// Drop bytes/sizes/futures for the least-recently-used pages once over the
  /// cap, skipping the pages still in use
  void _evictDistantPages() {
    if (_lru.length <= _maxCachedPages) return;
    final protected = <int>{
      _heroIndex,
      for (int d = -2; d <= 2; d++) _currentIndex + d,
    };
    for (var i = 0; i < _lru.length && _lru.length > _maxCachedPages;) {
      final index = _lru[i];
      if (protected.contains(index)) {
        i++;
        continue;
      }
      _lru.removeAt(i);
      _pageBytes.remove(index);
      _childSizes.remove(index);
      _imageDataFutures.remove(index);
    }
  }

  /// The child size, shrunk so its true-pixel size is at most
  /// doubleTapZoom * the viewport
  Size? _childSizeFor(int index, Size viewport) {
    final natural = _childSizes[index];
    if (natural == null || viewport.width <= 1 || viewport.height <= 1) {
      return natural;
    }
    final fit = math.min(
      viewport.width * _doubleTapZoom / natural.width,
      viewport.height * _doubleTapZoom / natural.height,
    );
    return fit >= 1.0 ? natural : natural * fit;
  }

  String get _currentImageId => widget.images[_currentIndex].id;

  /// The live page position, or the settled index before the controller
  /// is attached/measured.
  double get _page {
    if (_pageController.hasClients &&
        _pageController.position.haveDimensions) {
      return _pageController.page ?? _currentIndex.toDouble();
    }
    return _currentIndex.toDouble();
  }

  /// Crossfades the blurred backdrop continuously across a swipe by stacking
  /// the two adjacent backgrounds and driving the upper one's opacity from the
  /// fractional page position.
  Widget _buildBackground() {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        final page = _page;
        final lower = page.floor().clamp(0, widget.images.length - 1);
        final upper = page.ceil().clamp(0, widget.images.length - 1);
        final t = (page - lower).clamp(0.0, 1.0);

        final lowerBytes = _pageBytes[lower];
        final upperBytes = _pageBytes[upper];
        return Stack(
          fit: StackFit.expand,
          children: [
            // Solid base so a mid-fade never reveals black behind the top layer
            if (lowerBytes != null)
              _ViewerBackground(
                key: ValueKey(lower),
                imageBytes: lowerBytes,
              ),
            if (upper != lower && upperBytes != null)
              Opacity(
                opacity: t,
                child: _ViewerBackground(
                  key: ValueKey(upper),
                  imageBytes: upperBytes,
                ),
              ),
          ],
        );
      },
    );
  }

  // Memoized so a given page always hands the same Future to its FutureBuilders
  // avoiding waiting-state flicker on rebuild.
  final Map<int, Future<ImageData>> _imageDataFutures = {};

  Future<ImageData> _imageDataFor(int index) {
    _touch(index);
    return _imageDataFutures.putIfAbsent(index, () {
      if (index == widget.initialIndex) {
        return Future.value(widget.initialImageData);
      }
      return widget.getImageData(widget.images[index].id);
    });
  }

  Widget _buildOverlay() {
    final imageId = _currentImageId;
    return AnimatedBuilder(
      animation: _controlsAnim,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_controlsAnim.value);
        return IgnorePointer(
          ignoring: t == 0,
          child: FutureBuilder<ImageData>(
            future: _imageDataFor(_currentIndex),
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null) return const SizedBox.shrink();
              final uploader = widget.userCache[data.uploadedBy] ??
                  krab_user.User(id: data.uploadedBy, username: '');
              return ViewerOverlay(
                key: ValueKey(imageId),
                imageId: imageId,
                groupId: widget.groupId,
                imageData: data,
                uploader: uploader,
                commentCount: widget.commentCountCache[imageId] ?? 0,
                progress: t,
                flingToCommentsEnabled: !_isZoomed,
                loadBestBytesForSave: () async =>
                    await widget.getCachedImage(imageId, lowRes: false) ??
                    await widget.getCachedImage(imageId, lowRes: true),
                onCommentCountChanged: (delta) =>
                    widget.onCommentCountChanged?.call(imageId, delta),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBackground()),
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.7)),
          ),
          Positioned.fill(
            child: PhotoViewGallery.builder(
              pageController: _pageController,
              itemCount: widget.images.length,
              onPageChanged: _onPageChanged,
              scaleStateChangedCallback: _onScaleStateChanged,
              backgroundDecoration:
                  const BoxDecoration(color: Colors.transparent),
              builder: (context, index) {
                _touch(index);
                final imageId = widget.images[index].id;
                return PhotoViewGalleryPageOptions.customChild(
                  childSize: _childSizeFor(index, viewport),
                  minScale: PhotoViewComputedScale.contained,
                  initialScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.contained * 10,
                  scaleStateCycle: _doubleTapZoomCycle,
                  // Only the page nearest center gets a Hero
                  heroAttributes: index == _heroIndex
                      ? PhotoViewHeroAttributes(tag: "image_$imageId")
                      : null,
                  child: _ViewerPhoto(
                    key: ValueKey(imageId),
                    // Seed from the prefetch cache so a known page paints its
                    // low-res image on the first frame instead of flashing
                    initialBytes: _pageBytes[index],
                    imageDataFuture: _imageDataFor(index),
                    fullFuture: widget.getOrStartFullResFuture(imageId),
                    onLowBytes: (bytes) => _cachePageBytes(index, bytes),
                    onNaturalSize: (size) => _setChildSize(index, size),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(child: _buildOverlay()),
        ],
      ),
    );
  }
}

/// The zoomable content for one page: the low-res image shown immediately with
/// the full-res image crossfading in on top once it loads
class _ViewerPhoto extends StatefulWidget {
  final Uint8List? initialBytes;
  final Future<ImageData> imageDataFuture;
  final Future<Uint8List?> fullFuture;
  final void Function(Uint8List lowBytes) onLowBytes;
  final void Function(Size naturalSize) onNaturalSize;

  const _ViewerPhoto({
    super.key,
    required this.initialBytes,
    required this.imageDataFuture,
    required this.fullFuture,
    required this.onLowBytes,
    required this.onNaturalSize,
  });

  @override
  State<_ViewerPhoto> createState() => _ViewerPhotoState();
}

class _ViewerPhotoState extends State<_ViewerPhoto> {
  Uint8List? _low;
  Uint8List? _full;

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

  Future<void> _loadLow() async {
    final data = await widget.imageDataFuture;
    if (!mounted) return;
    setState(() => _low = data.imageBytes);
    widget.onLowBytes(data.imageBytes);
    _resolveNaturalSize(data.imageBytes);
  }

  /// Decodes the image's natural size and reports it up so PhotoView can use it
  /// as the child size.
  void _resolveNaturalSize(Uint8List bytes) {
    final stream = MemoryImage(bytes).resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      if (!mounted) return;
      final nW = info.image.width.toDouble();
      final nH = info.image.height.toDouble();
      if (nW > 0 && nH > 0) widget.onNaturalSize(Size(nW, nH));
    });
    stream.addListener(listener);
  }

  Future<void> _loadFull() async {
    final full = await widget.fullFuture;
    if (!mounted || full == null) return;
    await precacheImage(MemoryImage(full), context);
    if (!mounted) return;
    setState(() => _full = full);
    // Upgrade the child size to the full-res dimensions so double-tap zooms to
    // true pixels.
    _resolveNaturalSize(full);
  }

  @override
  Widget build(BuildContext context) {
    final low = _low;
    // Transparent until the low-res bytes arrive so the blurred backdrop shows
    // through instead of flashing black during a fast swipe onto a new page.
    if (low == null) return const SizedBox.expand();
    return Stack(
      fit: StackFit.expand,
      children: [
        // Low-res base, always visible
        Image.memory(
          low,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
        // Full-res fades in on top of the low-res base
        if (_full != null)
          TweenAnimationBuilder<double>(
            key: ValueKey<int>(_full.hashCode),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            tween: Tween<double>(begin: 0, end: 1),
            builder: (context, value, child) =>
                Opacity(opacity: value, child: child),
            child: Image.memory(
              _full!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          ),
      ],
    );
  }
}

class _ViewerBackground extends StatefulWidget {
  final Uint8List imageBytes;
  const _ViewerBackground({super.key, required this.imageBytes});

  @override
  State<_ViewerBackground> createState() => _ViewerBackgroundState();
}

class _ViewerBackgroundState extends State<_ViewerBackground> {
  Uint8List? _computedBytes;
  bool _showComputed = false;

  @override
  void initState() {
    super.initState();
    _computeBlur();
  }

  Future<void> _computeBlur() async {
    final bytes =
        await compute(createBlurredBackgroundBytes, widget.imageBytes);
    if (!mounted || bytes == null) return;
    setState(() => _computedBytes = bytes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _showComputed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Transform.scale(
        scale: 1.2,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Image.memory(
                widget.imageBytes,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
              ),
            ),
            if (_computedBytes != null)
              AnimatedOpacity(
                duration: const Duration(seconds: 1),
                curve: Curves.easeOut,
                opacity: _showComputed ? 1.0 : 0.0,
                child: Image.memory(
                  _computedBytes!,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
