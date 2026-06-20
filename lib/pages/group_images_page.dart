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
import 'package:krab/pages/viewer/image_gallery_page.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';

class GroupImagesPage extends StatefulWidget {
  final Group group;
  final String? imageId;

  const GroupImagesPage({super.key, required this.group, this.imageId});

  @override
  GroupPageState createState() => GroupPageState();
}

class GroupPageState extends State<GroupImagesPage> {
  late Future<SupabaseResponse<List<ImageRef>>> _groupImagesFuture;

  /// Caches
  final Map<String, Uint8List> _lowResCache = {};
  final Map<String, Uint8List> _fullResCache = {};
  final Map<String, Future<Uint8List?>> _fullResFutureCache = {};
  final Map<String, Future<ImageData>> _imageFutureCache = {};
  final Map<String, krab_user.User> _userCache = {};
  final Map<String, int> _commentCountCache = {};

  @override
  void initState() {
    super.initState();
    _groupImagesFuture = getGroupImages(widget.group.id);

    // If an imageId is provided, navigate to it
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.imageId == null) return;

      try {
        final imagesResponse = await _groupImagesFuture;
        if (!mounted) return;
        final images = imagesResponse.data ?? [];
        final initialIndex =
            images.indexWhere((img) => img.id == widget.imageId!);
        final initialData = await _getImageDataFuture(widget.imageId!);
        if (!mounted) return;
        final idx = initialIndex >= 0 ? initialIndex : 0;

        Navigator.push(
          context,
          _galleryRoute(ImageGalleryPage(
            images: images,
            initialIndex: idx,
            initialImageData: initialData,
            initialUploader: _userCache[initialData.uploadedBy] ??
                krab_user.User(id: initialData.uploadedBy, username: ''),
            groupId: widget.group.id,
            getImageData: _getImageDataFuture,
            getOrStartFullResFuture: _getOrStartFullResFuture,
            getCachedImage: _getCachedImage,
            commentCountCache: _commentCountCache,
            userCache: _userCache,
            onCommentCountChanged: _onCommentCountChanged,
          )),
        );
      } catch (err) {
        debugPrint("Failed to preload image: $err");
      }
    });
  }

  @override
  void dispose() {
    _lowResCache.clear();
    _fullResCache.clear();
    _fullResFutureCache.clear();
    _imageFutureCache.clear();
    _userCache.clear();
    _commentCountCache.clear();
    super.dispose();
  }

  Future<Uint8List?> _getCachedImage(String imageId,
      {bool lowRes = true}) async {
    final cache = lowRes ? _lowResCache : _fullResCache;
    if (cache.containsKey(imageId)) {
      debugPrint("Image $imageId (${lowRes ? 'low' : 'full'}) from cache");
      return cache[imageId];
    }

    final response = await getImage(imageId, lowRes: lowRes);
    if (response.success && response.data != null) {
      debugPrint("Image $imageId (${lowRes ? 'low' : 'full'}) downloaded");
      cache[imageId] = response.data!;
      return response.data!;
    }
    return null;
  }

  Future<ImageData> _getImageDataFuture(String imageId) {
    if (_imageFutureCache.containsKey(imageId)) {
      return _imageFutureCache[imageId]!;
    }
    final future = _fetchImageData(imageId);
    _imageFutureCache[imageId] = future;
    return future;
  }

  Future<Uint8List?> _getOrStartFullResFuture(String imageId) {
    if (_fullResFutureCache.containsKey(imageId)) {
      return _fullResFutureCache[imageId]!;
    }
    final future = _getCachedImage(imageId, lowRes: false);
    _fullResFutureCache[imageId] = future;
    return future;
  }

  Future<ImageData> _fetchImageData(String imageId) async {
    final imageBytes = await _getCachedImage(imageId, lowRes: true);
    if (imageBytes == null) throw Exception("Error downloading low-res image");

    final imageDetailsResponse = await getImageDetails(imageId);
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
    if (!_commentCountCache.containsKey(imageId)) {
      final commentResponse = await getCommentCount(imageId, widget.group.id);
      _commentCountCache[imageId] =
          (commentResponse.success && commentResponse.data != null)
              ? commentResponse.data!
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

  Future<void> _refreshGroupImages() async {
    setState(() {
      _groupImagesFuture = getGroupImages(widget.group.id);

      _lowResCache.clear();
      _fullResCache.clear();
      _fullResFutureCache.clear();
      _imageFutureCache.clear();
      _userCache.clear();
      _commentCountCache.clear();
    });

    await _groupImagesFuture;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        actions: [
          IconButton(
            icon: const Icon(Symbols.settings_rounded, fill: 1),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GroupSettingsPage(group: widget.group),
              ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<SupabaseResponse<List<ImageRef>>>(
        future: _groupImagesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
                child: Text(context.l10n
                    .error_loading_images(snapshot.error.toString())));
          }
          final images = snapshot.data!.data!;
          if (images.isEmpty) {
            return Center(child: Text(context.l10n.no_images));
          }

          return RefreshIndicator(
              onRefresh: _refreshGroupImages,
              child: GridView.builder(
                padding: const EdgeInsets.only(bottom: 8.0),
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                itemCount: images.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 4.0,
                  mainAxisSpacing: 4.0,
                  childAspectRatio: 1,
                ),
                itemBuilder: (context, index) {
                  final imageId = images[index].id;

                  return FutureBuilder<ImageData>(
                    future: _getImageDataFuture(imageId),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: Colors.grey[350],
                          ),
                          child:
                              const Center(child: CircularProgressIndicator()),
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
                        onTap: () {
                          _getOrStartFullResFuture(imageId);
                          Navigator.push(
                            context,
                            _galleryRoute(ImageGalleryPage(
                              images: images,
                              initialIndex: index,
                              initialImageData: imageData,
                              initialUploader: uploader,
                              groupId: widget.group.id,
                              getImageData: _getImageDataFuture,
                              getOrStartFullResFuture: _getOrStartFullResFuture,
                              getCachedImage: _getCachedImage,
                              commentCountCache: _commentCountCache,
                              userCache: _userCache,
                              onCommentCountChanged: _onCommentCountChanged,
                            )),
                          );
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
                              (_commentCountCache[imageId] ?? 0) > 0
                                  ? Positioned(
                                      top: 8,
                                      right: 8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.black
                                              .withValues(alpha: 0.6),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Symbols.comment_rounded,
                                              size: 12,
                                              color: Colors.white,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              (_commentCountCache[imageId] ?? 0)
                                                  .toString(),
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.white,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                              if (imageData.description != null &&
                                  imageData.description!.isNotEmpty)
                                Positioned(
                                  bottom: 6,
                                  right: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.black.withValues(alpha: 0.6),
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
                },
              ));
        },
      ),
    );
  }
}

PageRoute<void> _galleryRoute(Widget page) => PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );
