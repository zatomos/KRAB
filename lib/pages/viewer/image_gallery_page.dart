import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/image_data.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/pages/viewer/image_viewer.dart';

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

/// Full-screen, swipeable gallery of a group's images with a blurred backdrop
class ImageGalleryPage extends StatefulWidget {
  final List<ImageRef> images;
  final int initialIndex;
  final ImageData initialImageData;
  final krab_user.User initialUploader;

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

  const ImageGalleryPage({
    super.key,
    required this.images,
    required this.initialIndex,
    required this.initialImageData,
    required this.initialUploader,
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
  State<ImageGalleryPage> createState() => _ImageGalleryPageState();
}

class _ImageGalleryPageState extends State<ImageGalleryPage> {
  late final PageController _pageController;
  final ValueNotifier<bool> _isZoomed = ValueNotifier(false);
  late int _currentIndex;
  // Bytes cached here as pages load so background never needs an async lookup
  final Map<int, Uint8List> _pageBytes = {};
  final ValueNotifier<int> _pointerCount = ValueNotifier(0);

  // Start fetching the next page once within this many images of the end
  static const int _loadMoreThreshold = 3;
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(_onPageScroll);
    _pageBytes[widget.initialIndex] = widget.initialImageData.imageBytes;
    // The entry image may already sit near the end of the loaded set
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  void _onPageScroll() {
    final page = _pageController.page;
    if (page == null) return;
    final nearest = page.round();
    if (nearest != _currentIndex) {
      setState(() => _currentIndex = nearest);
      _maybeLoadMore();
    }
  }

  /// Pull in the next page when the user nears the end of the loaded images
  Future<void> _maybeLoadMore() async {
    if (_isLoadingMore || widget.loadMore == null) return;
    if (!(widget.hasMore?.call() ?? false)) return;
    if (_currentIndex < widget.images.length - _loadMoreThreshold) return;

    _isLoadingMore = true;
    await widget.loadMore!();
    if (!mounted) return;
    // Rebuild so the PageView picks up the newly appended images.
    setState(() => _isLoadingMore = false);
  }

  void _cachePageBytes(int index, Uint8List bytes) {
    if (_pageBytes.containsKey(index)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_pageBytes.containsKey(index)) {
        setState(() => _pageBytes[index] = bytes);
      }
    });
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    _isZoomed.dispose();
    _pointerCount.dispose();
    super.dispose();
  }

  Widget _buildPage(
      String imageId, int index, ImageData imageData, krab_user.User uploader) {
    _cachePageBytes(index, imageData.imageBytes);
    return ImageViewer(
      key: ValueKey(imageId),
      uploader: uploader,
      imageId: imageId,
      groupId: widget.groupId,
      lowResImageData: imageData,
      commentCount: widget.commentCountCache[imageId] ?? 0,
      loadFullImage: () => widget.getCachedImage(imageId, lowRes: false),
      preloadedFullImage: widget.getOrStartFullResFuture(imageId),
      zoomNotifier: _isZoomed,
      onCommentCountChanged: (delta) =>
          widget.onCommentCountChanged?.call(imageId, delta),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        onPointerDown: (_) => _pointerCount.value++,
        onPointerUp: (_) =>
            _pointerCount.value = (_pointerCount.value - 1).clamp(0, 10),
        onPointerCancel: (_) =>
            _pointerCount.value = (_pointerCount.value - 1).clamp(0, 10),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _pageBytes.containsKey(_currentIndex)
                    ? _GalleryBackground(
                        key: ValueKey(_currentIndex),
                        imageBytes: _pageBytes[_currentIndex]!,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            Positioned.fill(
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.7)),
            ),
            Positioned.fill(
              child: ListenableBuilder(
                listenable: Listenable.merge([_isZoomed, _pointerCount]),
                builder: (context, _) {
                  return PageView.builder(
                    controller: _pageController,
                    physics: (_isZoomed.value || _pointerCount.value > 1)
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    onPageChanged: (_) => _isZoomed.value = false,
                    itemCount: widget.images.length,
                    itemBuilder: (context, index) {
                      final imageId = widget.images[index].id;
                      if (index == widget.initialIndex) {
                        return _buildPage(imageId, index,
                            widget.initialImageData, widget.initialUploader);
                      }
                      return FutureBuilder<ImageData>(
                        future: widget.getImageData(imageId),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          final imageData = snapshot.data!;
                          final uploader =
                              widget.userCache[imageData.uploadedBy] ??
                                  krab_user.User(
                                      id: imageData.uploadedBy, username: '');
                          return _buildPage(
                              imageId, index, imageData, uploader);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GalleryBackground extends StatefulWidget {
  final Uint8List imageBytes;
  const _GalleryBackground({super.key, required this.imageBytes});

  @override
  State<_GalleryBackground> createState() => _GalleryBackgroundState();
}

class _GalleryBackgroundState extends State<_GalleryBackground> {
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
