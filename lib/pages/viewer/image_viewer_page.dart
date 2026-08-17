import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:extended_image/extended_image.dart';

import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/image_data.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/services/blur_worker.dart';
import 'package:krab/services/shared_image_api.dart';
import 'package:krab/pages/viewer/posted_in_badge.dart';
import 'package:krab/pages/viewer/viewer_photo.dart';
import 'package:krab/pages/viewer/viewer_overlay.dart';
import 'package:krab/themes/frosted_palette.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/services/cache/avatar_cache.dart';
import 'package:krab/services/cache/feed_image_cache.dart';

/// Where the viewer's decoded photos are held.
const String viewerImageCacheName = 'krab_viewer_photos';
const int _viewerCacheImages = 3;
const int _viewerCacheBytes = 64 << 20;

int _openViewers = 0;

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

/// Full-screen, swipeable viewer for a feed of images with a blurred backdrop.
/// Opened from ImageFeedPage, which owns the image list and caches.
class ImageViewerPage extends StatefulWidget {
  /// The gallery being viewed, one entry per image.
  final List<SharedImage> images;
  final int initialIndex;
  final ImageData initialImageData;

  /// Natural pixel size of the entry image
  final Size? initialImageSize;

  /// Raise the comments sheet over the entry image as soon as it lands.
  final bool openComments;

  /// The group being viewed, or null for the cross-group recent images gallery.
  final Group? group;

  /// The gallery's cache, shared with the feed underneath so swiping between
  /// images and closing back to the grid never re-downloads what is loaded.
  final FeedImageCache cache;
  final void Function(SharedImage image, int delta)? onCommentCountChanged;
  final void Function(SharedImage image)? onImageDeleted;

  /// An image was changed by its uploader, so the gallery underneath can show
  /// the new description too.
  final void Function(SharedImage image, String description)?
      onDescriptionChanged;

  /// Copies that appeared on servers this image was not on before, so the list
  /// behind the viewer can fold them into it.
  final void Function(List<ImageRef> copies)? onCopiesAdded;

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
    this.openComments = false,
    required this.group,
    required this.cache,
    this.onCommentCountChanged,
    this.onImageDeleted,
    this.onDescriptionChanged,
    this.onCopiesAdded,
    this.onImageChanged,
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
  // The page nearest screen-center, so popping mid-swipe flies a single image.
  late int _heroIndex;

  // Bytes cached here as pages load so the background never needs an async
  // lookup, keyed by page index.
  final Map<int, Uint8List> _pageBytes = {};
  // Pre-blurred backdrop bytes per page
  final Map<int, Uint8List?> _blurredBg = {};
  // Natural image size per page, used to compute the contained on-screen rect
  // Resolved lazily, except the entry page which is seeded up front to keep its
  // hero flight stable.
  final Map<int, Size> _childSizes = {};

  // The overlay chrome fades in once the hero flight settles, so it doesn't
  // flicker as the flying image passes over and behind it
  late final AnimationController _controlsAnim;

  bool _isZoomed = false;
  ImageData? _lastImageData;

  // Start fetching the next page once within this many images of the end
  static const int _loadMoreThreshold = 3;
  bool _isLoadingMore = false;

  // Still owing the entry image its comments sheet. Dropped as soon as the user
  // swipes, so a photo they moved on to never has it appear over it.
  late bool _pendingComments = widget.openComments;

  // Cap on how many pages' bytes/sizes/futures are retained.
  static const int _maxCachedPages = 7;
  final List<int> _lru = [];

  @override
  void initState() {
    super.initState();
    imageCaches.putIfAbsent(viewerImageCacheName, ImageCache.new)
      ..maximumSize = _viewerCacheImages
      ..maximumSizeBytes = _viewerCacheBytes;
    _openViewers++;

    _currentIndex = widget.initialIndex;
    _heroIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
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
      _prefetchAround(widget.initialIndex);
    });
  }

  ModalRoute<dynamic>? _route;

  /// Whether the hero has finished flying and this page is simply on screen.
  bool _settled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_onRouteStatus);
      _route = route;
      _route?.animation?.addStatusListener(_onRouteStatus);
      _settled = _route?.animation?.isCompleted ?? false;
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    // Hide the overlay chrome the moment the page starts popping.
    if (status == AnimationStatus.reverse) _controlsAnim.value = 0;

    final settled = status == AnimationStatus.completed;
    if (settled != _settled) setState(() => _settled = settled);
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteStatus);
    _pageController.removeListener(_onScroll);
    _pageController.dispose();
    _controlsAnim.dispose();
    if (--_openViewers == 0) {
      clearMemoryImageCache(viewerImageCacheName);
      BlurWorker.instance.stop();
    }
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
      _pendingComments = false;
      _currentIndex = index;
      // A freshly settled page always starts fitted to the screen
      _isZoomed = false;
    });
    widget.onImageChanged?.call(index);
    _maybeLoadMore();
    _prefetchAround(index);
    _evictDistantPages();
  }

  /// Warm the page on screen and the ones on either side of it.
  void _prefetchAround(int index) {
    _prefetch(index, isCurrent: true);
    _prefetch(index - 1);
    _prefetch(index + 1);
  }

  void _prefetch(int index, {bool isCurrent = false}) {
    if (index < 0 || index >= widget.images.length) return;
    final image = widget.images[index];

    if (!isCurrent && widget.group == null) {
      SharedImageApi(image).warmReactions();
    }
    _prefetchPostedIn(image);

    _imageDataFor(index).then((data) {
      if (!mounted) return;
      _cachePageBytes(index, data.imageBytes);
      precacheAvatar(context, widget.cache.user(image));
    });
  }

  Future<void> _prefetchPostedIn(SharedImage image) async {
    final groups = await SharedImageApi(image).postedInGroups();
    if (!mounted || groups == null) return;
    final shown = [
      ...groups.where((g) => g.id == widget.group?.id),
      ...groups.where((g) => g.id != widget.group?.id),
    ].take(postedInBadgeMaxIcons);
    for (final group in shown) {
      precacheGroupIcon(context, group);
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
    if (_blurredBg.containsKey(index)) return;
    _blurredBg[index] = null;
    BlurWorker.instance.blur(srcBytes).then((bytes) {
      if (!mounted) return;
      if (bytes == null) {
        _blurredBg.remove(index);
        return;
      }
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

  SharedImage get _currentImage => widget.images[_currentIndex];

  /// The live page position, or the settled index before the controller
  /// is attached/measured.
  double get _page {
    if (_pageController.hasClients && _pageController.position.haveDimensions) {
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
      return widget.cache.imageData(widget.images[index]);
    });
  }

  /// Carry a rewording into the page this viewer already holds, so swiping away
  /// and back shows the new text, then let the gallery underneath know.
  void _onDescriptionChanged(SharedImage image, String description) {
    final held = _imageDataFutures[_currentIndex];
    if (held != null) {
      _imageDataFutures[_currentIndex] =
          held.then((data) => data.withDescription(description));
    }
    widget.onDescriptionChanged?.call(image, description);
  }

  Widget _buildOverlay() {
    final image = _currentImage;
    return AnimatedBuilder(
      animation: _controlsAnim,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_controlsAnim.value);
        return IgnorePointer(
          ignoring: t < 1,
          child: FutureBuilder<ImageData>(
            future: _imageDataFor(_currentIndex),
            initialData: _lastImageData,
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null) return const SizedBox.shrink();
              _lastImageData = data;
              // The instance has to be the one the id came from, not the
              // primary: the details are read from whichever copy answered
              final uploader = widget.cache.user(image) ??
                  krab_user.User(
                      instanceId: data.uploaderInstanceId,
                      id: data.uploadedBy,
                      username: '');
              return ViewerOverlay(
                image: image,
                group: widget.group,
                imageData: data,
                uploader: uploader,
                commentCount: widget.cache.commentCount(image),
                openComments: _pendingComments,
                progress: t,
                uploadedAt: widget.images[_currentIndex].uploadedAt,
                flingToCommentsEnabled: !_isZoomed,
                loadBestBytesForSave: () => widget.cache.bestBytes(image),
                onCommentCountChanged: (delta) =>
                    widget.onCommentCountChanged?.call(image, delta),
                onDescriptionChanged: (description) =>
                    _onDescriptionChanged(image, description),
                onImageDeleted: widget.onImageDeleted,
                onCopiesAdded: widget.onCopiesAdded,
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsFor(Brightness.dark),
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: GestureDetector(
          onTap: _toggleChrome,
          child: Stack(
            children: [
              Positioned.fill(child: _buildBackground()),
              Positioned.fill(
                child: ColoredBox(color: context.frostedVeil),
              ),
              Positioned.fill(
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    gestureSettings: const DeviceGestureSettings(
                      touchSlop: kPagingTouchSlop,
                    ),
                  ),
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: widget.images.length,
                    onPageChanged: _onPageChanged,
                    physics: _isZoomed
                        ? const NeverScrollableScrollPhysics()
                        : const _SnappyPageScrollPhysics(),
                    itemBuilder: (context, index) {
                      _touch(index);
                      final pagePhoto = widget.images[index];
                      return RepaintBoundary(
                        child: ViewerPhoto(
                          key: ValueKey(pagePhoto.identity),
                          imageCacheName: viewerImageCacheName,
                          displaySize: _displaySizeFor(index, viewport),
                          heroTag: index == _heroIndex
                              ? "image_${pagePhoto.identity}"
                              : null,
                          initialBytes: _pageBytes[index],
                          imageDataFuture: _imageDataFor(index),
                          fullFuture: widget.cache.fullResBytes(pagePhoto),
                          onLowBytes: (bytes) => _cachePageBytes(index, bytes),
                          onNaturalSize: (size) => _setChildSize(index, size),
                          onZoomChanged: _onPageZoomChanged,
                          onTap: _toggleChrome,
                          settled: _settled,
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned.fill(child: _buildOverlay()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The blurred backdrop behind a page, faded in once its blur is ready.
class _ViewerBackground extends StatelessWidget {
  final Uint8List? blurredBytes;
  const _ViewerBackground({super.key, required this.blurredBytes});

  @override
  Widget build(BuildContext context) {
    final bytes = blurredBytes;
    return RepaintBoundary(
      child: AnimatedOpacity(
        opacity: bytes != null ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: bytes == null
            ? const SizedBox.expand()
            : ClipRect(
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
