import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/models/Group.dart';
import 'package:krab/models/User.dart' as KRAB_User;
import 'package:krab/models/ImageData.dart';
import 'package:krab/pages/GroupSettingsPage.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/UserAvatar.dart';
import 'package:krab/widgets/CommentsBottomSheet.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/filesaver.dart';


class GroupImagesPage extends StatefulWidget {
  final Group group;
  final String? imageId;

  const GroupImagesPage({super.key, required this.group, this.imageId});

  @override
  GroupPageState createState() => GroupPageState();
}

class GroupPageState extends State<GroupImagesPage> {
  late Future<SupabaseResponse<List<dynamic>>> _groupImagesFuture;
  bool _isAdmin = false;

  /// Caches
  final Map<String, Uint8List> _lowResCache = {};
  final Map<String, Uint8List> _fullResCache = {};
  final Map<String, Future<ImageData>> _imageFutureCache = {};
  final Map<String, KRAB_User.User> _userCache = {};
  final Map<String, int> _commentCountCache = {};

  @override
  void initState() {
    super.initState();
    _groupImagesFuture = getGroupImages(widget.group.id);
    _checkAdminStatus();

    // If an imageId is provided, show its preview after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.imageId != null) {
        _getImageDataFuture(widget.imageId!).then((data) {
          _showImagePreview(widget.imageId!, data);
        });
      }
    });
  }

  @override
  void dispose() {
    _lowResCache.clear();
    _fullResCache.clear();
    _imageFutureCache.clear();
    _userCache.clear();
    _commentCountCache.clear();
    super.dispose();
  }

  Future<void> _checkAdminStatus() async {
    final adminStatus = await isAdmin(widget.group.id);
    if (adminStatus.success) {
      setState(() {
        _isAdmin = adminStatus.data!;
      });
    }
  }

  Future<Uint8List?> _getCachedImage(String imageId, {bool lowRes = true}) async {
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

  Future<ImageData> _fetchImageData(String imageId) async {
    final imageBytes = await _getCachedImage(imageId, lowRes: true);
    if (imageBytes == null) throw Exception("Error downloading low-res image");

    final imageDetailsResponse = await getImageDetails(imageId);
    if (!imageDetailsResponse.success || imageDetailsResponse.data == null) {
      throw Exception("Error fetching image details: ${imageDetailsResponse.error}");
    }

    final Map<String, dynamic> imageDetails = imageDetailsResponse.data!;
    final String uploaderId = imageDetails['uploaded_by'];

    // Cache username
    if (!_userCache.containsKey(uploaderId)) {
      final userResponse = await getUserDetails(uploaderId);
      _userCache[uploaderId] =
      (userResponse.success && userResponse.data != null)
          ? userResponse.data!
          : KRAB_User.User(id: uploaderId, username: "");
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
      createdAt: imageDetails['created_at'],
      description: imageDetails['description'],
    );
  }

  void _showImagePreview(String imageId, ImageData imageData) {
    final uploader = _userCache[imageData.uploadedBy] ?? KRAB_User.User(
      id: imageData.uploadedBy,
      username: "",
    );
    final commentCount = _commentCountCache[imageId] ?? 0;

    showDialog(
      context: context,
      builder: (context) {
        return FutureBuilder<Uint8List?>(
          future: _getCachedImage(imageId, lowRes: false),
          builder: (context, fullSnapshot) {
            final imageBytes = fullSnapshot.data ?? imageData.imageBytes;
            return Dialog(
              child: ConstrainedBox(
                constraints:
                BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.9),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Center(
                                  child: Image.memory(
                                    imageBytes,
                                    fit: BoxFit.contain,
                                    width: constraints.maxWidth,
                                    gaplessPlayback: true,
                                  ),
                                ),
                                Positioned(
                                  top: 5,
                                  right: 5,
                                  child: IconButton(
                                    icon: const Icon(Icons.download,
                                        color: Colors.white),
                                    onPressed: () async {
                                      bool success = await downloadImage(
                                        imageBytes,
                                        imageData.uploadedBy,
                                        imageData.createdAt,
                                      );
                                      showSnackBar(
                                        context,
                                        success
                                            ? context.l10n.image_saved_success
                                            : context.l10n.error_saving_image,
                                        color:
                                        success ? Colors.green : Colors.red,
                                      );
                                    },
                                  ),
                                ),
                                Positioned(
                                  top: 5,
                                  left: 5,
                                  child: IconButton(
                                    icon: const Icon(Icons.close,
                                        color: Colors.white),
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      ListTile(
                        title: Text(
                          uploader.username,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          imageData.description ?? "",
                          style: TextStyle(
                            color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.comment),
                          label: Text(context.l10n
                              .comments_count(commentCount.toString())),
                          onPressed: () => _showCommentsBottomSheet(
                            imageData.uploadedBy,
                            imageId,
                            widget.group.id,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showCommentsBottomSheet(
      String uploaderId, String imageId, String groupId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => CommentsBottomSheet(
        uploaderId: uploaderId,
        imageId: imageId,
        groupId: groupId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    GroupSettingsPage(group: widget.group, isAdmin: _isAdmin),
              ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<SupabaseResponse<List<dynamic>>>(
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

          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: GridView.builder(
              itemCount: images.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 4.0,
                mainAxisSpacing: 4.0,
                childAspectRatio: 1,
              ),
              itemBuilder: (context, index) {
                final image = images[index];
                final imageId = image['id'].toString();

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
                        child: const Icon(Icons.error, size: 50),
                      );
                    }

                    final imageData = snapshot.data!;
                    final uploader =
                        _userCache[imageData.uploadedBy] ?? KRAB_User.User(
                          id: imageData.uploadedBy,
                          username: "",
                        );

                    return GestureDetector(
                      onTap: () => _showImagePreview(imageId, imageData),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(
                              imageData.imageBytes,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                            Align(
                              alignment: Alignment.bottomRight,
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: UserAvatar(uploader, radius: 20),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}