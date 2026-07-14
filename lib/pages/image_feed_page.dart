import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/feed_events.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/image_data.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/pages/group_settings_page.dart';
import 'package:krab/pages/groups_page.dart';
import 'package:krab/pages/viewer/image_viewer_page.dart';
import 'package:krab/services/cache/feed_image_cache.dart';
import 'package:krab/services/cache/reaction_cache.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';

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

  /// True once a `new_image` push lands for this feed while it's open
  bool _hasNewPhotos = false;
  StreamSubscription<NewImageEvent>? _newImageSub;

  /// The bytes, uploaders and tallies for the images on screen. Shared with the
  /// viewer this page opens.
  late final FeedImageCache _cache = FeedImageCache(groupId: _groupId);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _newImageSub = FeedEvents.instance.newImages.listen(_onNewImage);
    _bootstrap();
  }

  /// Surface the new photos pill when an incoming image belongs to this feed
  void _onNewImage(NewImageEvent event) {
    final relevant = _groupId == null || event.groupId == _groupId;
    if (!relevant || _hasNewPhotos || !mounted) return;
    setState(() => _hasNewPhotos = true);
  }

  /// Refresh to the top in response to the new photos pill.
  Future<void> _loadNewPhotos() async {
    await _refreshGroupImages();
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
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

      final initialData = await _cache.imageData(widget.imageId!);
      if (!mounted) return;

      // The image is somewhere in the loaded feed: open the gallery on it, with
      // its neighbors to swipe through. If it isn't, show it on its own rather
      // than opening the gallery at index 0.
      final found = index >= 0;
      await _openViewer(
        images: found
            ? _images
            : [
                ImageRef(
                  id: widget.imageId!,
                  uploadedBy: initialData.uploadedBy,
                  uploadedAt: DateTime.tryParse(initialData.createdAt),
                )
              ],
        index: found ? index : 0,
        data: initialData,
        paginated: found,
      );
    } catch (err) {
      debugPrint("Failed to preload image: $err");
    }
  }

  /// Open the full-screen gallery on one image..
  Future<void> _openViewer({
    required List<ImageRef> images,
    required int index,
    required ImageData data,
    bool paginated = true,
  }) async {
    // Decode the size first so the viewer's hero flight is stable.
    final initialSize = await decodeImageSize(data.imageBytes);
    if (!mounted) return;

    await Navigator.push(
      context,
      _viewerRoute(ImageViewerPage(
        images: images,
        initialIndex: index,
        initialImageData: data,
        initialImageSize: initialSize,
        groupId: _groupId,
        cache: _cache,
        onCommentCountChanged: _onCommentCountChanged,
        onImageDeleted: _onImageDeleted,
        onImageChanged: paginated ? _revealTile : null,
        loadMore: paginated ? _loadMore : null,
        hasMore: paginated ? () => _hasMore : null,
      )),
    );

    // Reaction badges may have changed in the viewer; rebuild.
    if (mounted) setState(() {});
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
    _newImageSub?.cancel();
    _scrollController.dispose();
    _cache.clear();
    super.dispose();
  }

  /// Drop a deleted image from the list and every cache so it disappears from
  /// the grid.
  void _onImageDeleted(String imageId) {
    _cache.evict(imageId);
    if (!mounted) return;
    setState(() => _images.removeWhere((img) => img.id == imageId));
  }

  void _onCommentCountChanged(String imageId, int delta) {
    setState(() => _cache.addToCommentCount(imageId, delta));
  }

  /// Pull-to-refresh
  Future<void> _refreshGroupImages() async {
    final response = await _fetchPage();
    if (!mounted || !response.success || response.data == null) return;
    final page = response.data!;
    setState(() {
      _cache.clear();
      _images
        ..clear()
        ..addAll(page);
      _hasMore = page.length == _kPageSize;
      _error = null;
      _hasNewPhotos = false;
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
      body: Stack(
        children: [
          _buildBody(context),
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(child: _newPhotosPill(context)),
          ),
        ],
      ),
    );
  }

  Widget _newPhotosPill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSlide(
      offset: _hasNewPhotos ? Offset.zero : const Offset(0, -2),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      child: AnimatedOpacity(
        opacity: _hasNewPhotos ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: IgnorePointer(
          ignoring: !_hasNewPhotos,
          child: Material(
            color: scheme.primary,
            elevation: 4,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _loadNewPhotos,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.arrow_upward_rounded,
                        size: 18, color: scheme.onPrimary),
                    const SizedBox(width: 6),
                    Text(
                      context.l10n.new_photos,
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
      future: _cache.imageData(imageId),
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
        final uploader = _cache.user(imageData.uploadedBy) ??
            krab_user.User(id: imageData.uploadedBy, username: "");
        final hasDescription = imageData.description?.isNotEmpty ?? false;
        final reactions = _reactionCountFor(imageId);
        final comments = _cache.commentCount(imageId);

        return GestureDetector(
          onTap: () {
            _cache.fullResBytes(imageId);
            _openViewer(images: _images, index: index, data: imageData);
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
                  bottom: hasDescription ? 12 : 8,
                  right: hasDescription ? 12 : 8,
                  child: UserAvatar(uploader, radius: 20),
                ),
                if (reactions > 0 || comments > 0)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        if (reactions > 0)
                          _countBadge(
                            Symbols.emoji_emotions_rounded,
                            reactions,
                            borderColor:
                                const Color(0xFFFFC107).withValues(alpha: 0.8),
                          ),
                        if (comments > 0)
                          _countBadge(
                            Symbols.comment_rounded,
                            comments,
                            borderColor:
                                const Color(0xFF42A5F5).withValues(alpha: 0.8),
                          ),
                      ],
                    ),
                  ),
                if (hasDescription)
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
      cachedReactionTotal(imageId) ?? _cache.reactionCount(imageId);

  /// A small frosted count badge for the grid tile corner.
  Widget _countBadge(IconData icon, int count, {Color? borderColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: borderColor != null
            ? Border.all(color: borderColor, width: 1)
            : null,
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
