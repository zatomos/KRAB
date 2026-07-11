import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';
import 'package:image/image.dart' as img;

import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/image_data.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/pages/viewer/viewer_overlay.dart';
import 'package:krab/widgets/reactions_bar.dart';

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

/// Page physics with a stiff spring so a swipe snaps to the next image quickly
class _SnappyPageScrollPhysics extends ClampingScrollPhysics {
  const _SnappyPageScrollPhysics({super.parent});

  @override
  _SnappyPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnappyPageScrollPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.4,
        stiffness: 220,
        ratio: 1.1,
      );
}

/// Downscales and gaussian-blurs an image off the main isolate for the gallery
/// backdrop.
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
  final void Function(String imageId)? onImageDeleted;

  /// Reports the index the viewer settles on as the user swipes, so the gallery
  /// underneath can keep that image's thumbnail on-screen for the hero return.
  final void Function(int index)? onImageChanged;

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
    this.initialImageSize,
    required this.groupId,
    required this.getImageData,
    required this.getOrStartFullResFuture,
    required this.getCachedImage,
    required this.commentCountCache,
    required this.userCache,
    this.onCommentCountChanged,
    this.onImageDeleted,
    this.onImageChanged,
    this.loadMore,
    this.hasMore,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  late final ExtendedPageController _pageController;
  late int _currentIndex;
  // The page nearest screen-center. Only this page carries a Hero, so popping
  // mid-swipe flies a single image, not both.
  late int _heroIndex;

  // Bytes cached here as pages load so the background never needs an async
  // lookup, keyed by page index.
  final Map<int, Uint8List> _pageBytes = {};
  // Pre-blurred backdrop bytes per page
  final Map<int, Uint8List> _blurredBg = {};
  final Set<int> _blurInFlight = {};
  // Natural image size per page, used to compute the contained on-screen rect
  // Resolved lazily, except the entry page which is seeded up front to keep its
  // hero flight stable.
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
  // order and evicts the least-recently-used page once over the cap,
  // never touching the pages currently in use.
  static const int _maxCachedPages = 7;
  final List<int> _lru = [];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _heroIndex = widget.initialIndex;
    _pageController = ExtendedPageController(initialPage: widget.initialIndex);
    _pageController.addListener(_onScroll);
    _pageBytes[widget.initialIndex] = widget.initialImageData.imageBytes;
    _ensureBlur(widget.initialIndex, widget.initialImageData.imageBytes);
    if (widget.initialImageSize != null) {
      _childSizes[widget.initialIndex] = widget.initialImageSize!;
    }
    _touch(widget.initialIndex);

    _controlsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
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

  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_onRouteStatus);
      _route = route;
      _route?.animation?.addStatusListener(_onRouteStatus);
    }
  }

  /// Hide the overlay chrome the moment the page starts popping
  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) _controlsAnim.value = 0;
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteStatus);
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
    widget.onImageChanged?.call(index);
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
      fetchPostedInGroups(widget.images[i].id);
      fetchImageReactions(widget.images[i].id);
      if (_pageBytes.containsKey(i)) continue;
      _imageDataFor(i).then((data) {
        if (mounted) _cachePageBytes(i, data.imageBytes);
      });
    }
  }

  /// A single tap anywhere toggles every piece of overlay chrome.
  void _toggleChrome() {
    final showing = _controlsAnim.status == AnimationStatus.forward ||
        _controlsAnim.status == AnimationStatus.completed;
    if (showing) {
      _controlsAnim.reverse();
    } else {
      _controlsAnim.forward();
    }
  }

  void _onPageZoomChanged(bool zoomed) {
    if (zoomed == _isZoomed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && zoomed != _isZoomed) setState(() => _isZoomed = zoomed);
    });
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
    _ensureBlur(index, bytes);
    if (_pageBytes.containsKey(index)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_pageBytes.containsKey(index)) {
        setState(() => _pageBytes[index] = bytes);
        _touch(index);
      }
    });
  }

  /// Build the page's pre-blurred backdrop off-thread once
  void _ensureBlur(int index, Uint8List srcBytes) {
    if (_blurredBg.containsKey(index) || _blurInFlight.contains(index)) return;
    _blurInFlight.add(index);
    compute(createBlurredBackgroundBytes, srcBytes).then((bytes) {
      _blurInFlight.remove(index);
      if (!mounted || bytes == null) return;
      setState(() => _blurredBg[index] = bytes);
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
      _blurredBg.remove(index);
      _childSizes.remove(index);
      _imageDataFutures.remove(index);
    }
  }

  /// The image's contained on-screen rect
  /// Used as the hero's tight target size. Falls back to the full viewport
  /// until the natural size is known.
  Size _displaySizeFor(int index, Size viewport) {
    final natural = _childSizes[index];
    if (natural == null || natural.width <= 0 || natural.height <= 0) {
      return viewport;
    }
    final s = math.min(
      viewport.width / natural.width,
      viewport.height / natural.height,
    );
    return Size(natural.width * s, natural.height * s);
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

        return Stack(
          fit: StackFit.expand,
          children: [
            _ViewerBackground(
              key: ValueKey(lower),
              blurredBytes: _blurredBg[lower],
            ),
            if (upper != lower)
              Opacity(
                opacity: t,
                child: _ViewerBackground(
                  key: ValueKey(upper),
                  blurredBytes: _blurredBg[upper],
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
          ignoring: t < 1,
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
                uploadedAt: widget.images[_currentIndex].uploadedAt,
                flingToCommentsEnabled: !_isZoomed,
                loadBestBytesForSave: () async =>
                    await widget.getCachedImage(imageId, lowRes: false) ??
                    await widget.getCachedImage(imageId, lowRes: true),
                onCommentCountChanged: (delta) =>
                    widget.onCommentCountChanged?.call(imageId, delta),
                onImageDeleted: widget.onImageDeleted,
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: GestureDetector(
        onTap: _toggleChrome,
        child: Stack(
        children: [
          Positioned.fill(child: _buildBackground()),
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.7)),
          ),
          Positioned.fill(
            child: ExtendedImageGesturePageView.builder(
              controller: _pageController,
              itemCount: widget.images.length,
              onPageChanged: _onPageChanged,
              physics: const _SnappyPageScrollPhysics(),
              itemBuilder: (context, index) {
                _touch(index);
                final imageId = widget.images[index].id;
                return _ViewerPhoto(
                  key: ValueKey(imageId),
                  displaySize: _displaySizeFor(index, viewport),
                  // Only the page nearest center gets a Hero
                  heroTag: index == _heroIndex ? "image_$imageId" : null,
                  // Seed from the prefetch cache so a known page paints its
                  // low-res image on the first frame instead of flashing
                  initialBytes: _pageBytes[index],
                  imageDataFuture: _imageDataFor(index),
                  fullFuture: widget.getOrStartFullResFuture(imageId),
                  onLowBytes: (bytes) => _cachePageBytes(index, bytes),
                  onNaturalSize: (size) => _setChildSize(index, size),
                  onZoomChanged: _onPageZoomChanged,
                );
              },
            ),
          ),
          Positioned.fill(child: _buildOverlay()),
        ],
        ),
      ),
    );
  }
}

/// The zoomable content for one page: the low-res image shown immediately with
/// the full-res image crossfading in on top once it loads
class _ViewerPhoto extends StatefulWidget {
  final Size displaySize;
  final String? heroTag;
  final Uint8List? initialBytes;
  final Future<ImageData> imageDataFuture;
  final Future<Uint8List?> fullFuture;
  final void Function(Uint8List lowBytes) onLowBytes;
  final void Function(Size naturalSize) onNaturalSize;
  final void Function(bool zoomed) onZoomChanged;

  const _ViewerPhoto({
    super.key,
    required this.displaySize,
    required this.heroTag,
    required this.initialBytes,
    required this.imageDataFuture,
    required this.fullFuture,
    required this.onLowBytes,
    required this.onNaturalSize,
    required this.onZoomChanged,
  });

  @override
  State<_ViewerPhoto> createState() => _ViewerPhotoState();
}

class _ViewerPhotoState extends State<_ViewerPhoto>
    with SingleTickerProviderStateMixin {
  Uint8List? _low;
  Uint8List? _full;

  static const double _doubleTapScale = 2.5;

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

  /// Decodes the image's natural size and reports it up so the page can compute
  /// the contained rect
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
    _resolveNaturalSize(full);
  }

  GestureConfig _initGestureConfig(ExtendedImageState state) {
    return GestureConfig(
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
  }

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

  @override
  Widget build(BuildContext context) {
    final low = _low;
    // Transparent until the low-res bytes arrive so the blurred backdrop shows
    // through instead of flashing black during a fast swipe onto a new page.
    if (low == null) return const SizedBox.expand();

    // Low-res base
    Widget base = Image.memory(
      low,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
    if (widget.heroTag != null) {
      base = Hero(tag: widget.heroTag!, child: base);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: SizedBox.fromSize(size: widget.displaySize, child: base),
        ),
        AnimatedOpacity(
          opacity: _full != null ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: ExtendedImage.memory(
            _full ?? low,
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

class _ViewerBackground extends StatelessWidget {
  final Uint8List? blurredBytes;
  const _ViewerBackground({super.key, required this.blurredBytes});

  @override
  Widget build(BuildContext context) {
    final bytes = blurredBytes;
    return AnimatedOpacity(
      opacity: bytes != null ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      child: bytes == null
          ? const SizedBox.expand()
          : RepaintBoundary(
              child: ClipRect(
                child: Transform.scale(
                  scale: 1.2,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
    );
  }
}
