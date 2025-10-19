import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/models/Group.dart';
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

  // In-memory cache for images
  final Map<String, Uint8List> _imageCache = {};

  // Cache for futures
  final Map<String, Future<ImageData>> _imageFutureCache = {};

  @override
  void initState() {
    super.initState();
    _groupImagesFuture = getGroupImages(widget.group.id);
    _checkAdminStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.imageId != null) {
        _showImagePreview(widget.imageId!);
      }
    });
  }

  @override
  void dispose() {
    _imageCache.clear();
    _imageFutureCache.clear();
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

  Future<Uint8List?> _getCachedImage(String imageId) async {
    if (_imageCache.containsKey(imageId)) {
      debugPrint("Image $imageId found in cache");
      return _imageCache[imageId];
    } else {
      final response = await getImage(imageId);
      if (response.success && response.data != null) {
        debugPrint("Image $imageId downloaded");
        _imageCache[imageId] = response.data!;
        return response.data!;
      }
    }
    return null;
  }

  // Get or create a cached future for image data
  Future<ImageData> _getImageDataFuture(String imageId) {
    if (_imageFutureCache.containsKey(imageId)) {
      return _imageFutureCache[imageId]!;
    }

    final future = _fetchImageData(imageId);
    _imageFutureCache[imageId] = future;
    return future;
  }

  Future<ImageData> _fetchImageData(String imageId) async {
    final imageBytes = await _getCachedImage(imageId);
    if (imageBytes == null) {
      throw Exception("Error downloading image");
    }

    final imageDetailsResponse = await getImageDetails(imageId);
    if (!imageDetailsResponse.success || imageDetailsResponse.data == null) {
      throw Exception(
          "Error fetching image details: ${imageDetailsResponse.error}");
    }
    final Map<String, dynamic> imageDetails = imageDetailsResponse.data!;

    final String uploaderId = imageDetails['uploaded_by'];

    return ImageData(
      imageBytes: imageBytes,
      uploadedBy: uploaderId,
      createdAt: imageDetails['created_at'],
      description: imageDetails['description'],
    );
  }

  Future<ui.Image> _getImageInfo(Uint8List imageBytes) async {
    final Completer<ui.Image> completer = Completer();
    ui.decodeImageFromList(imageBytes, (ui.Image img) {
      completer.complete(img);
    });
    return completer.future;
  }

  void _showImagePreview(String imageId) {
    showDialog(
      context: context,
      builder: (context) {
        return FutureBuilder<ImageData>(
          future: _getImageDataFuture(imageId), // Use cached future
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Dialog(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.5,
                  height: MediaQuery.of(context).size.height * 0.8,
                  child: const Center(child: CircularProgressIndicator()),
                ),
              );
            } else if (snapshot.hasError) {
              return Dialog(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.5,
                  height: MediaQuery.of(context).size.height * 0.8,
                  child: Center(child: Text("Error: ${snapshot.error}")),
                ),
              );
            } else if (snapshot.hasData) {
              final imageData = snapshot.data!;
              return Dialog(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.9,
                  ),
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
                                      imageData.imageBytes,
                                      fit: BoxFit.contain,
                                      width: constraints.maxWidth,
                                      gaplessPlayback: true, // Prevents flicker
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
                                          imageData.imageBytes,
                                          imageData.uploadedBy,
                                          imageData.createdAt,
                                        );
                                        showSnackBar(
                                          context,
                                          success
                                              ? context.l10n.image_saved_success
                                              : context.l10n.error_saving_image,
                                          color: success
                                              ? Colors.green
                                              : Colors.red,
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
                                      onPressed: () => Navigator.of(context).pop(),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        FutureBuilder(
                          future: getUsername(imageData.uploadedBy),
                          builder: (context, snapshot) {
                            String uploaderName = " ";
                            if (snapshot.connectionState ==
                                ConnectionState.done) {
                              if (snapshot.hasError ||
                                  !snapshot.hasData ||
                                  !(snapshot.data as SupabaseResponse).success ||
                                  (snapshot.data as SupabaseResponse).data == null) {
                                uploaderName = "Unknown user";
                              } else {
                                uploaderName =
                                (snapshot.data as SupabaseResponse).data!;
                              }
                            }
                            return ListTile(
                              title: Text(
                                uploaderName,
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                imageData.description ?? "",
                                style: TextStyle(
                                  color: GlobalThemeData.darkColorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            );
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.comment),
                            label: FutureBuilder(
                              future: getCommentCount(imageId, widget.group.id),
                              builder: (context, snapshot) {
                                if (snapshot.connectionState ==
                                    ConnectionState.waiting) {
                                  return Text(context.l10n.comments_count("..."));
                                } else if (snapshot.hasError ||
                                    !snapshot.hasData ||
                                    !(snapshot.data as SupabaseResponse).success) {
                                  return Text(context.l10n.comments_count("0"));
                                } else {
                                  final count = (snapshot.data
                                  as SupabaseResponse)
                                      .data;
                                  return Text(context.l10n.comments_count(count.toString()));
                                }
                              },
                            ),
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
            }
            return const SizedBox();
          },
        );
      },
    );
  }

  void _showCommentsBottomSheet(String uploaderId, String imageId, String groupId) {
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
                child: Text(context.l10n.error_loading_images(snapshot.error.toString())));
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
                            color: Colors.grey[350]
                        ),
                        child: const Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (!snapshot.hasData) {
                      return Container(
                        color: Colors.grey,
                        child: const Icon(Icons.error, size: 50),
                      );
                    }
                    final imageData = snapshot.data!;
                    return GestureDetector(
                      onTap: () => _showImagePreview(imageId),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            FutureBuilder<ui.Image>(
                              future: _getImageInfo(imageData.imageBytes),
                              builder: (context, snapshot) {
                                if (snapshot.hasData) {
                                  final imgInfo = snapshot.data!;
                                  final halfWidth = (imgInfo.width / 4).round();
                                  final halfHeight = (imgInfo.height / 4).round();
                                  return Image.memory(
                                    imageData.imageBytes,
                                    fit: BoxFit.cover,
                                    cacheWidth: halfWidth,
                                    cacheHeight: halfHeight,
                                    gaplessPlayback: true,
                                  );
                                } else {
                                  return Image.memory(
                                    imageData.imageBytes,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  );
                                }
                              },
                            ),
                            Align(
                              alignment: Alignment.bottomRight,
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: FutureBuilder(
                                  future: getUsername(imageData.uploadedBy),
                                  builder: (context, snapshot) {
                                    String displayName = "";
                                    if (snapshot.connectionState == ConnectionState.done) {
                                      if (snapshot.hasError ||
                                          !snapshot.hasData ||
                                          !(snapshot.data as SupabaseResponse).success ||
                                          (snapshot.data as SupabaseResponse).data == null) {
                                        displayName = "Unknown user";
                                      } else {
                                        displayName = (snapshot.data as SupabaseResponse).data!;
                                      }
                                    }
                                    return UserAvatar(displayName, radius: 20);
                                  },
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
            ),
          );
        },
      ),
    );
  }
}