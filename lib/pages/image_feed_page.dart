import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/feed_events.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/image_data.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/services/shared_image_api.dart';
import 'package:krab/pages/group_settings_page.dart';
import 'package:krab/pages/groups_page.dart';
import 'package:krab/pages/viewer/image_viewer_page.dart';
import 'package:krab/services/cache/feed_image_cache.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/instance/instance_registry.dart';

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
  /// The group to show images for, or null for the cross-group "recent images"
  /// view that aggregates the latest images from every group the user is in.
  final Group? group;
  final String? imageId;

  const ImageFeedPage({super.key, this.group, this.imageId});

  @override
  ImageFeedPageState createState() => ImageFeedPageState();
}

class ImageFeedPageState extends State<ImageFeedPage> {
  /// The group being viewed, or null in cross-group recent images mode.
  String? get _groupId => widget.group?.id;

  /// Paginated image list, loaded incrementally as the user scrolls.
  /// The images on screen, one entry per image however many servers hold it.
  final List<SharedImage> _images = [];

  /// Every copy loaded so far, across every page.
  ///
  /// Merging runs over all of it rather than over one page, because two copies
  /// of one image can land on different pages: they are uploaded seconds apart
  /// and ordered by time, so a page boundary can fall between them. Merged per
  /// page, the second copy would arrive as an image the list already holds and
  /// be discarded, taking its comments with it.
  final List<ImageRef> _refs = [];

  /// `instanceId/id` of everything in _refs, so a copy that arrives twice
  /// is only held once.
  final Set<String> _refKeys = {};

  /// Where each instance's paging got to, so the next page can be asked of
  /// every server independently. They run at their own pace, and merging puts
  /// the combined result back in order.
  final Map<String, ImageRef> _cursors = {};

  /// Signed-in instances whose last page failed.
  List<KrabInstance> _unavailable = const [];

  /// Instances that have run out of images.
  final Set<String> _exhausted = {};
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
  /// The server a group gallery reads from. Null in the cross-group feed.
  late final KrabInstance? _instance = widget.group == null
      ? null
      : InstanceRegistry.instance.byId(widget.group!.instanceId);

  late final FeedImageCache _cache =
      FeedImageCache(groupId: _groupId, instanceId: _instance?.id);

  /// The instances this feed reads from.
  List<KrabInstance> get _sources {
    final instance = _instance;
    if (widget.group == null) return InstanceRegistry.instance.all;
    return instance == null ? const [] : [instance];
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _newImageSub = FeedEvents.instance.newImages.listen(_onNewImage);
    _bootstrap();
  }

  /// Surface the new images pill when an incoming image belongs to this feed
  void _onNewImage(NewImageEvent event) {
    final relevant = _groupId == null || event.groupId == _groupId;
    if (!relevant || _hasNewPhotos || !mounted) return;
    setState(() => _hasNewPhotos = true);
  }

  /// Refresh to the top in response to the new images pill.
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

  /// Whether this feed reads from every server the device is connected to.
  bool get _spansEveryInstance =>
      _sources.length == InstanceRegistry.instance.all.length;

  /// Take a freshly fetched page into _refs and rebuild the merged list.
  Future<List<SharedImage>> _absorb(List<ImageRef> page) async {
    final incoming = <ImageRef>[...page];
    if (!_spansEveryInstance) {
      incoming.addAll(await siblingCopiesOf(page));
    }
    _ingest(incoming);
    return _rebuild();
  }

  /// Hold copies that are not already held.
  void _ingest(Iterable<ImageRef> refs) {
    for (final ref in refs) {
      if (_refKeys.add('${ref.instanceId}/${ref.id}')) _refs.add(ref);
    }
  }

  /// Collapse everything held into the list on screen.
  List<SharedImage> _rebuild() {
    final order = [for (final i in InstanceRegistry.instance.all) i.id];
    final images = mergeImages(_refs, instanceOrder: order);

    if (_sources.length > 1) sortImagesNewestFirst(images);
    return images;
  }

  /// A copy of an image already on screen now exists somewhere it did not, so
  /// the image gains it without waiting for a listing to turn it up.
  void _onCopiesAdded(List<ImageRef> copies) {
    _ingest(copies);
    if (!mounted) return;
    final images = _rebuild();
    setState(() {
      _images
        ..clear()
        ..addAll(images);
    });
  }

  /// Forget everything loaded, so the next page starts from an empty list.
  void _resetRefs() {
    _refs.clear();
    _refKeys.clear();
  }

  /// Fetch one page from every instance this feed reads from.
  ///
  /// reset starts again from the top rather than continuing from the cursors.
  /// Returns null when nothing could be loaded at all.
  Future<List<ImageRef>?> _fetchPage({bool reset = false}) async {
    final sources = _sources;
    if (reset) {
      _cursors.clear();
      _exhausted.clear();
    }

    final pages = await Future.wait(sources.map((instance) async {
      if (_exhausted.contains(instance.id)) {
        return const SupabaseResponse<List<ImageRef>>(success: true, data: []);
      }
      final after = _cursors[instance.id];
      return _groupId != null
          ? instance.api.getGroupImages(
              _groupId!,
              limit: _kPageSize,
              beforeCreatedAt: after?.uploadedAt,
              beforeId: after?.id,
            )
          : instance.api.getLatestImages(
              _kPageSize,
              beforeCreatedAt: after?.uploadedAt,
              beforeId: after?.id,
            );
    }));

    final refs = <ImageRef>[];
    final failed = <KrabInstance>[];
    var anySucceeded = false;

    for (var i = 0; i < sources.length; i++) {
      final response = pages[i];
      if (!response.success || response.data == null) {
        debugPrint('Feed: ${sources[i].id} page failed (${response.error})');
        failed.add(sources[i]);
        continue;
      }
      anySucceeded = true;
      final page = response.data!;
      refs.addAll(page);

      // This instance has no more to give once it returns a short page.
      if (page.length < _kPageSize) {
        _exhausted.add(sources[i].id);
      } else if (page.isNotEmpty) {
        _cursors[sources[i].id] = page.last;
      }
    }

    // Say which servers are missing rather than quietly showing a short feed:
    // an image that isn't there looks the same as an image nobody posted.
    _unavailable = failed;

    if (!anySucceeded) return null;
    return refs;
  }

  bool get _moreRemains => _sources.any((i) => !_exhausted.contains(i.id));

  /// Load the first page, then, if deep-linking to an image, open it.
  Future<void> _bootstrap() async {
    await _loadInitial();
    if (widget.imageId == null || !mounted) return;

    try {
      // The target is usually recent, but page forward until it's found (or we
      // run out / hit the lookup cap) so the gallery can open on it.
      // A deep link names one copy, so match on any copy's id.
      bool holdsTarget(SharedImage p) =>
          p.copies.any((c) => c.id == widget.imageId);

      int index = _images.indexWhere(holdsTarget);
      int pages = 0;
      while (index < 0 && _hasMore && pages < _kDeepLinkMaxPages) {
        await _loadMore();
        if (!mounted) return;
        index = _images.indexWhere(holdsTarget);
        pages++;
      }

      // Not in the feed: show just that copy, still as an image in its own
      // right so everything below treats it the same way.
      // An image asked for by id but not in the feed can only be read from the
      // gallery's own server; the cross-group feed has none to guess with.
      final source = _instance;
      if (index < 0 && source == null) return;
      final target = index >= 0
          ? _images[index]
          : SharedImage(
              [ImageRef(instanceId: source!.id, id: widget.imageId!)]);

      final initialData = await _cache.imageData(target);
      if (!mounted) return;

      // The image is somewhere in the loaded feed: open the gallery on it, with
      // its neighbors to swipe through. If it isn't, show it on its own rather
      // than opening the gallery at index 0.
      final found = index >= 0;
      await _openViewer(
        images: found ? _images : [target],
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
    required List<SharedImage> images,
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
        group: widget.group,
        cache: _cache,
        onCommentCountChanged: _onCommentCountChanged,
        onImageDeleted: _onImageDeleted,
        onCopiesAdded: _onCopiesAdded,
        onImageChanged: paginated ? _revealTile : null,
        loadMore: paginated ? _loadMore : null,
        hasMore: paginated ? () => _hasMore : null,
      )),
    );

    // Reaction badges may have changed in the viewer; rebuild.
    if (mounted) setState(() {});
  }

  Future<void> _loadInitial() async {
    final page = await _fetchPage(reset: true);
    if (!mounted) return;
    if (page == null) {
      setState(() {
        _loadingInitial = false;
        _error = context.l10n.unknown_error;
      });
      return;
    }
    _resetRefs();
    final images = await _absorb(page);
    if (!mounted) return;
    setState(() {
      _images
        ..clear()
        ..addAll(images);
      _hasMore = _moreRemains;
      _loadingInitial = false;
      _error = null;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _images.isEmpty) return;
    setState(() => _loadingMore = true);

    final page = await _fetchPage();
    if (!mounted) return;
    if (page == null) {
      // Leave _hasMore set so a later scroll can retry.
      setState(() => _loadingMore = false);
      return;
    }
    // Merged against everything already loaded, so a copy of an image further
    // up the list joins it instead of being dropped as an image already shown.
    final images = await _absorb(page);
    if (!mounted) return;
    setState(() {
      _images
        ..clear()
        ..addAll(images);
      _hasMore = _moreRemains;
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
  void _onImageDeleted(SharedImage image) {
    _cache.evict(image);
    // Also out of the copies the merge runs over
    for (final copy in image.copies) {
      _refKeys.remove('${copy.instanceId}/${copy.id}');
    }
    _refs.removeWhere(
        (r) => image.copies.any((c) => c.instanceId == r.instanceId && c.id == r.id));
    if (!mounted) return;
    setState(() => _images.removeWhere((p) => p.identity == image.identity));
  }

  void _onCommentCountChanged(SharedImage image, int delta) {
    setState(() => _cache.addToCommentCount(image, delta));
  }

  /// Pull-to-refresh
  Future<void> _refreshGroupImages() async {
    final page = await _fetchPage(reset: true);
    if (!mounted || page == null) return;
    _resetRefs();
    final images = await _absorb(page);
    if (!mounted) return;
    setState(() {
      _cache.clear();
      _images
        ..clear()
        ..addAll(images);
      _hasMore = _moreRemains;
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
        title: widget.group != null
            ? Text(widget.group!.name)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Symbols.photo_library, fill: 1, size: 22),
                  const SizedBox(width: 10),
                  Flexible(child: Text(context.l10n.recent_photos)),
                ],
              ),
        actions: [
          if (widget.group != null)
            IconButton(
              icon: const Icon(Symbols.settings_rounded, fill: 1),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupSettingsPage(
                      group: widget.group!, instance: _instance!),
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

    final unavailable = _unavailable;

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
          if (unavailable.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    Icon(Symbols.cloud_off_rounded,
                        size: 18, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.l10n.feed_server_unavailable(
                            unavailable.map((i) => i.label).join(', ')),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
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
    final image = _images[index];

    return FutureBuilder<ImageData>(
      future: _cache.imageData(image),
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
        final uploader = _cache.user(image) ??
            krab_user.User(
                instanceId: image.primary.instanceId,
                id: imageData.uploadedBy,
                username: "");
        final hasDescription = imageData.description?.isNotEmpty ?? false;
        final reactions = _reactionCountFor(image);
        final comments = _cache.commentCount(image);

        return GestureDetector(
          onTap: () {
            _cache.fullResBytes(image);
            _openViewer(images: _images, index: index, data: imageData);
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                  tag: "image_${image.identity}",
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

  /// Total reactions for an image's badge, across every copy of it.
  int _reactionCountFor(SharedImage image) =>
      InstanceRegistry.instance
          .byId(image.primary.instanceId)
          ?.reactions
          .cachedTotal(image.primary.id) ??
      _cache.reactionCount(image);

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
