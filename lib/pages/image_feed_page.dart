import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/image_data.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/pages/group_settings_page.dart';
import 'package:krab/pages/groups_page.dart';
import 'package:krab/pages/viewer/image_viewer_page.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/reactions_bar.dart';

/// Number of images fetched per page in both the single-group and cross-group
/// galleries. New pages load as the user scrolls.
const int _kPageSize = 30;

/// When deep-linking to a specific image, how many pages to load while
/// searching for it before giving up. The target should be recent,
/// so it lands in the first page or two.
const int _kDeepLinkMaxPages = 10;

/// Paginated grid of a group's images. Owns the image list, caches and
/// pagination, and opens the full-screen [ImageViewerPage] when an image
/// is tapped.
class ImageFeedPage extends StatefulWidget {
  /// The group to show images for, or null for the cross-group "recent photos"
  /// view that aggregates the latest images from every group the user is in.
  final Group? group;
  final String? imageId;

  const ImageFeedPage({super.key, this.group, this.imageId});

  @override
  ImageFeedPageState createState() => ImageFeedPageState();
}

class ImageFeedPageState extends State<ImageFeedPage> {
  /// The group being viewed, or null in cross-group recent photos mode.
  String? get _groupId => widget.group?.id;

  /// Paginated image list, loaded incrementally as the user scrolls.
  final List<ImageRef> _images = [];
  final ScrollController _scrollController = ScrollController();
  bool _loadingInitial = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  /// Caches
  final Map<String, Uint8List> _lowResCache = {};
  final Map<String, Uint8List> _fullResCache = {};
  final Map<String, Future<Uint8List?>> _fullResFutureCache = {};
  final Map<String, Future<ImageData>> _imageFutureCache = {};
  final Map<String, krab_user.User> _userCache = {};
  final Map<String, int> _commentCountCache = {};
  final Map<String, int> _reactionCountCache = {};

  /// LRU bound on how many images' decoded bytes are retained, so memory stays
  /// bounded while paging through an arbitrarily long feed. The lightweight
  /// caches are not evicted. lruOrder lists image ids from least to
  /// most-recently accessed.
  static const int _maxCachedImages = 60;
  final List<String> _lruOrder = [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  /// Fetch one page. With after set, fetches the page following that image;
  /// otherwise fetches the first page.
  Future<SupabaseResponse<List<ImageRef>>> _fetchPage({ImageRef? after}) =>
      _groupId != null
          ? getGroupImages(
              _groupId!,
              limit: _kPageSize,
              beforeCreatedAt: after?.uploadedAt,
              beforeId: after?.id,
            )
          : getLatestImages(
              _kPageSize,
              beforeCreatedAt: after?.uploadedAt,
              beforeId: after?.id,
            );

  /// Load the first page, then, if deep-linking to an image, open it.
  Future<void> _bootstrap() async {
    await _loadInitial();
    if (widget.imageId == null || !mounted) return;

    try {
      // The target is usually recent, but page forward until it's found (or we
      // run out / hit the lookup cap) so the gallery can open on it.
      int index = _images.indexWhere((img) => img.id == widget.imageId);
      int pages = 0;
      while (index < 0 && _hasMore && pages < _kDeepLinkMaxPages) {
        await _loadMore();
        if (!mounted) return;
        index = _images.indexWhere((img) => img.id == widget.imageId);
        pages++;
      }

      final initialData = await _getImageDataFuture(widget.imageId!);
      if (!mounted) return;
      final idx = index >= 0 ? index : 0;
      final initialSize = await decodeImageSize(initialData.imageBytes);
      if (!mounted) return;

      Navigator.push(
        context,
        _viewerRoute(ImageViewerPage(
          images: _images,
          initialIndex: idx,
          initialImageData: initialData,
          initialImageSize: initialSize,
          groupId: _groupId,
          getImageData: _getImageDataFuture,
          getOrStartFullResFuture: _getOrStartFullResFuture,
          getCachedImage: _getCachedImage,
          commentCountCache: _commentCountCache,
          userCache: _userCache,
          onCommentCountChanged: _onCommentCountChanged,
          onImageDeleted: _onImageDeleted,
          onImageChanged: _revealTile,
          loadMore: _loadMore,
          hasMore: () => _hasMore,
        )),
      ).then((_) {
        // Reaction badges may have changed in the viewer; rebuild
        if (mounted) setState(() {});
      });
    } catch (err) {
      debugPrint("Failed to preload image: $err");
    }
  }

  Future<void> _loadInitial() async {
    final response = await _fetchPage();
    if (!mounted) return;
    if (!response.success || response.data == null) {
      setState(() {
        _loadingInitial = false;
        _error = response.error ?? context.l10n.unknown_error;
      });
      return;
    }
    final page = response.data!;
    setState(() {
      _images
        ..clear()
        ..addAll(page);
      _hasMore = page.length == _kPageSize;
      _loadingInitial = false;
      _error = null;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _images.isEmpty) return;
    final last = _images.last;
    // No cursor available means we can't page reliably; stop here.
    if (last.uploadedAt == null) {
      setState(() => _hasMore = false);
      return;
    }
    setState(() => _loadingMore = true);

    final response = await _fetchPage(after: last);
    if (!mounted) return;
    if (!response.success || response.data == null) {
      // Leave _hasMore set so a later scroll can retry.
      setState(() => _loadingMore = false);
      return;
    }
    final page = response.data!;
    final existing = _images.map((e) => e.id).toSet();
    setState(() {
      _images.addAll(page.where((e) => !existing.contains(e.id)));
      _hasMore = page.length == _kPageSize;
      _loadingMore = false;
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  /// Scrolls the grid so the tile at index is on-screen, but only when it
  /// isn't already. Called as the viewer swipes between images so closing it
  /// always heroes back to a visible thumbnail.
  void _revealTile(int index) {
    if (!_scrollController.hasClients) return;
    const crossAxisCount = 2;
    const spacing = 4.0;
    final width = MediaQuery.sizeOf(context).width;
    final tile = (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
    final rowExtent = tile + spacing;
    final rowTop = (index ~/ crossAxisCount) * rowExtent;
    final rowBottom = rowTop + tile;

    final position = _scrollController.position;
    final viewTop = position.pixels;
    final viewBottom = viewTop + position.viewportDimension;
    double? target;
    if (rowTop < viewTop) {
      target = rowTop;
    } else if (rowBottom > viewBottom) {
      target = rowBottom - position.viewportDimension;
    }
    if (target != null) {
      _scrollController.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _lowResCache.clear();
    _fullResCache.clear();
    _fullResFutureCache.clear();
    _imageFutureCache.clear();
    _userCache.clear();
    _commentCountCache.clear();
    _reactionCountCache.clear();
    _lruOrder.clear();
    super.dispose();
  }

  Future<Uint8List?> _getCachedImage(String imageId,
      {bool lowRes = true}) async {
    final cache = lowRes ? _lowResCache : _fullResCache;
    if (cache.containsKey(imageId)) {
      debugPrint("[feed] bytes HIT $imageId (${lowRes ? 'low' : 'full'})");
      return cache[imageId];
    }

    final response = await getImage(imageId, lowRes: lowRes);
    if (response.success && response.data != null) {
      cache[imageId] = response.data!;
      return response.data!;
    }
    return null;
  }

  /// Drop a deleted image from the list and every cache so it disappears from
  /// the grid.
  void _onImageDeleted(String imageId) {
    _lowResCache.remove(imageId);
    _fullResCache.remove(imageId);
    _fullResFutureCache.remove(imageId);
    _imageFutureCache.remove(imageId);
    _commentCountCache.remove(imageId);
    _reactionCountCache.remove(imageId);
    _lruOrder.remove(imageId);
    if (!mounted) return;
    setState(() => _images.removeWhere((img) => img.id == imageId));
  }

  Future<ImageData> _getImageDataFuture(String imageId) {
    // Mark as most-recently used and evict stale images before reading, so a
    // just-touched image is never the one dropped.
    _touchCache(imageId);
    final cached = _imageFutureCache[imageId];
    if (cached != null) {
      debugPrint("[feed] memo HIT $imageId (imageData)");
      return cached;
    }
    final future = _fetchImageData(imageId);
    _imageFutureCache[imageId] = future;
    return future;
  }

  /// Record [imageId] as most-recently accessed and drop the byte caches of any
  /// images that fall outside the LRU window.
  void _touchCache(String imageId) {
    _lruOrder
      ..remove(imageId)
      ..add(imageId);
    while (_lruOrder.length > _maxCachedImages) {
      final evicted = _lruOrder.removeAt(0);
      _lowResCache.remove(evicted);
      _fullResCache.remove(evicted);
      _fullResFutureCache.remove(evicted);
      _imageFutureCache.remove(evicted);
    }
  }

  Future<Uint8List?> _getOrStartFullResFuture(String imageId) {
    if (_fullResFutureCache.containsKey(imageId)) {
      debugPrint("[feed] memo HIT $imageId (fullres)");
      return _fullResFutureCache[imageId]!;
    }
    final future = _getCachedImage(imageId, lowRes: false);
    _fullResFutureCache[imageId] = future;
    return future;
  }

  Future<ImageData> _fetchImageData(String imageId) async {
    // Run the RPC calls in parallel
    final bytesFuture = _getCachedImage(imageId, lowRes: true);
    final detailsFuture = getImageDetails(imageId);
    final countFuture = _commentCountCache.containsKey(imageId)
        ? null
        : (_groupId != null
            ? getCommentCount(imageId, _groupId!)
            : getImageCommentCount(imageId));
    final reactionsFuture =
        _reactionCountCache.containsKey(imageId) ? null : getImageReactions(imageId);

    final imageBytes = await bytesFuture;
    if (imageBytes == null) throw Exception("Error downloading low-res image");

    final imageDetailsResponse = await detailsFuture;
    if (!imageDetailsResponse.success || imageDetailsResponse.data == null) {
      throw Exception(
          "Error fetching image details: ${imageDetailsResponse.error}");
    }

    final imageDetails = imageDetailsResponse.data!;
    final uploaderId = imageDetails.uploadedBy;

    // Cache username
    if (!_userCache.containsKey(uploaderId)) {
      final userResponse = await getUserDetails(uploaderId);
      _userCache[uploaderId] =
          (userResponse.success && userResponse.data != null)
              ? userResponse.data!
              : krab_user.User(id: uploaderId, username: "");
    }

    // Cache comment count
    if (countFuture != null) {
      final commentResponse = await countFuture;
      _commentCountCache[imageId] =
          (commentResponse.success && commentResponse.data != null)
              ? commentResponse.data!
              : 0;
    }

    // Cache total reaction count
    if (reactionsFuture != null) {
      final reactionsResponse = await reactionsFuture;
      _reactionCountCache[imageId] = (reactionsResponse.success &&
              reactionsResponse.data != null)
          ? reactionsResponse.data!.fold<int>(
              0, (sum, e) => sum + ((e['count'] as num?)?.toInt() ?? 0))
          : 0;
    }

    return ImageData(
      imageBytes: imageBytes,
      uploadedBy: uploaderId,
      createdAt: imageDetails.createdAt,
      description: imageDetails.description,
    );
  }

  void _onCommentCountChanged(String imageId, int delta) {
    setState(() {
      _commentCountCache[imageId] = (_commentCountCache[imageId] ?? 0) + delta;
    });
  }

  /// Pull-to-refresh
  Future<void> _refreshGroupImages() async {
    final response = await _fetchPage();
    if (!mounted || !response.success || response.data == null) return;
    final page = response.data!;
    setState(() {
      _lowResCache.clear();
      _fullResCache.clear();
      _fullResFutureCache.clear();
      _imageFutureCache.clear();
      _userCache.clear();
      _commentCountCache.clear();
      _reactionCountCache.clear();
      _lruOrder.clear();
      _images
        ..clear()
        ..addAll(page);
      _hasMore = page.length == _kPageSize;
      _error = null;
    });
  }

  /// Bring the user back to the group list, regardless of how this single
  /// group's gallery was reached
  void _backToGroupList() {
    final nav = Navigator.of(context);
    bool foundGroups = false;
    nav.popUntil((route) {
      if (route.settings.name == GroupsPage.routeName) foundGroups = true;
      return foundGroups || route.isFirst;
    });
    if (!foundGroups) {
      nav.push(MaterialPageRoute(
        settings: const RouteSettings(name: GroupsPage.routeName),
        builder: (_) => const GroupsPage(),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = _buildScaffold(context);
    // A single group's gallery always returns to the group list on back
    if (widget.group == null) return scaffold;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToGroupList();
      },
      child: scaffold,
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group?.name ?? context.l10n.recent_photos),
        actions: [
          if (widget.group != null)
            IconButton(
              icon: const Icon(Symbols.settings_rounded, fill: 1),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupSettingsPage(group: widget.group!),
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  /// The scrolling grid, with loading / empty / error states and a footer
  /// spinner while the next page loads.
  Widget _buildBody(BuildContext context) {
    if (_loadingInitial) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(context.l10n.error_loading_images(_error!)));
    }
    if (_images.isEmpty) {
      return Center(
          child: Text(widget.group != null
              ? context.l10n.no_images
              : context.l10n.no_recent_photos));
    }

    return RefreshIndicator(
      onRefresh: _refreshGroupImages,
      child: CustomScrollView(
        controller: _scrollController,
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.only(bottom: 8.0),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 4.0,
                mainAxisSpacing: 4.0,
                childAspectRatio: 1,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildTile(context, index),
                childCount: _images.length,
              ),
            ),
          ),
          if (_loadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context, int index) {
    final imageId = _images[index].id;

    return FutureBuilder<ImageData>(
      future: _getImageDataFuture(imageId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.grey[350],
            ),
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        if (!snapshot.hasData) {
          return Container(
            color: Colors.grey,
            child: const Icon(Symbols.error_rounded, size: 50),
          );
        }

        final imageData = snapshot.data!;
        final uploader = _userCache[imageData.uploadedBy] ??
            krab_user.User(
              id: imageData.uploadedBy,
              username: "",
            );

        return GestureDetector(
          onTap: () async {
            _getOrStartFullResFuture(imageId);
            // Decode the size first so the viewer's hero flight is stable
            final initialSize = await decodeImageSize(imageData.imageBytes);
            if (!context.mounted) return;
            Navigator.push(
              context,
              _viewerRoute(ImageViewerPage(
                images: _images,
                initialIndex: index,
                initialImageData: imageData,
                initialImageSize: initialSize,
                groupId: _groupId,
                getImageData: _getImageDataFuture,
                getOrStartFullResFuture: _getOrStartFullResFuture,
                getCachedImage: _getCachedImage,
                commentCountCache: _commentCountCache,
                userCache: _userCache,
                onCommentCountChanged: _onCommentCountChanged,
                onImageDeleted: _onImageDeleted,
                onImageChanged: _revealTile,
                loadMore: _loadMore,
                hasMore: () => _hasMore,
              )),
            ).then((_) {
              // Reaction badges may have changed in the viewer; rebuild
              if (mounted) setState(() {});
            });
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                  tag: "image_$imageId",
                  child: Image.memory(
                    imageData.imageBytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                  ),
                ),
                Positioned(
                  bottom: (imageData.description != null &&
                          imageData.description!.isNotEmpty)
                      ? 12
                      : 8,
                  right: (imageData.description != null &&
                          imageData.description!.isNotEmpty)
                      ? 12
                      : 8,
                  child: UserAvatar(uploader, radius: 20),
                ),
                if (_reactionCountFor(imageId) > 0 ||
                    (_commentCountCache[imageId] ?? 0) > 0)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_reactionCountFor(imageId) > 0)
                          _countBadge(
                            Symbols.emoji_emotions_rounded,
                            _reactionCountFor(imageId),
                            borderColor: const Color(0xFFFFC107).withValues(alpha: 0.8)
                          ),
                        if (_reactionCountFor(imageId) > 0 &&
                            (_commentCountCache[imageId] ?? 0) > 0)
                          const SizedBox(width: 4),
                        if ((_commentCountCache[imageId] ?? 0) > 0)
                          _countBadge(
                            Symbols.comment_rounded,
                            _commentCountCache[imageId]!,
                            borderColor:
                                const Color(0xFF42A5F5).withValues(alpha: 0.8),
                          ),
                      ],
                    ),
                  ),
                if (imageData.description != null &&
                    imageData.description!.isNotEmpty)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Symbols.notes_rounded,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Total reactions for an image's badge
  int _reactionCountFor(String imageId) =>
      cachedReactionTotal(imageId) ?? _reactionCountCache[imageId] ?? 0;

  /// A small frosted count badge for the grid tile corner.
  Widget _countBadge(IconData icon, int count, {Color? borderColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border:
            borderColor != null ? Border.all(color: borderColor, width: 1) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            count.toString(),
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

PageRoute<void> _viewerRoute(Widget page) => PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );
