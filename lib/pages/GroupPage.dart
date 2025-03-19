import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/models/Group.dart';
import 'package:krab/models/ImageData.dart';
import 'package:krab/pages/GroupSettingsPage.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/UserAvatar.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/filesaver.dart';

class GroupPage extends StatefulWidget {
  final Group group;

  const GroupPage({super.key, required this.group});

  @override
  GroupPageState createState() => GroupPageState();
}

class GroupPageState extends State<GroupPage> {
  late Future<SupabaseResponse<List<dynamic>>> _groupImagesFuture;
  bool _isAdmin = false;

  // In-memory cache for images
  final Map<String, Uint8List> _imageCache = {};

  @override
  void initState() {
    super.initState();
    _groupImagesFuture = getGroupImages(widget.group.id);
    _checkAdminStatus();
  }

  @override
  void dispose() {
    _imageCache.clear();
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

  Future<ImageData> _fetchImageData(String imageId) async {
    // Retrieve image bytes from cache or download
    final imageBytes = await _getCachedImage(imageId);
    if (imageBytes == null) {
      throw Exception("Error downloading image");
    }

    // Retrieve image details
    final imageDetailsResponse = await getImageDetails(imageId);
    if (!imageDetailsResponse.success || imageDetailsResponse.data == null) {
      throw Exception(
          "Error fetching image details: ${imageDetailsResponse.error}");
    }
    final Map<String, dynamic> imageDetails = imageDetailsResponse.data!;

    // Retrieve uploader's username
    final usernameResponse = await getUsername(imageDetails['uploaded_by']);
    if (!usernameResponse.success || usernameResponse.data == null) {
      throw Exception("Error fetching username: ${usernameResponse.error}");
    }
    final String uploadedBy = usernameResponse.data!;

    return ImageData(
      imageBytes: imageBytes,
      uploadedBy: uploadedBy,
      createdAt: imageDetails['created_at'],
      description: imageDetails['description'],
    );
  }

  // Decode image dimensions
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
          future: _fetchImageData(imageId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Dialog(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.9,
                  height: MediaQuery.of(context).size.height * 0.8,
                  child: const Center(child: CircularProgressIndicator()),
                ),
              );
            } else if (snapshot.hasError) {
              return Dialog(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.9,
                  height: MediaQuery.of(context).size.height * 0.8,
                  child: Center(child: Text("Error: ${snapshot.error}")),
                ),
              );
            } else if (snapshot.hasData) {
              final imageData = snapshot.data!;
              return Dialog(
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.9,
                    maxHeight: MediaQuery.of(context).size.height * 0.8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.9,
                          maxHeight: MediaQuery.of(context).size.height * 0.6,
                        ),
                        child: Stack(
                          fit: StackFit.passthrough,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: Image.memory(imageData.imageBytes),
                              ),
                            ),
                            Positioned(
                              top: 10,
                              right: 10,
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
                                          ? "Image saved successfully"
                                          : "Error saving image",
                                      color:
                                          success ? Colors.green : Colors.red);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      ListTile(
                        title: Text(
                          imageData.uploadedBy,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          imageData.description ?? "",
                          style: TextStyle(
                            color: GlobalThemeData
                                .darkColorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text("Close"),
                      ),
                    ],
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
                child: Text("Error loading images: ${snapshot.error}"));
          }
          final images = snapshot.data!.data!;
          if (images.isEmpty) {
            return const Center(child: Text("No images in this group."));
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
                  future: _fetchImageData(imageId),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: Colors.grey[300],
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
                                  final halfWidth = (imgInfo.width / 4)
                                      .round(); // 1/4th of original size for efficiency
                                  final halfHeight =
                                      (imgInfo.height / 4).round();
                                  return Image.memory(
                                    imageData.imageBytes,
                                    fit: BoxFit.cover,
                                    cacheWidth: halfWidth,
                                    cacheHeight: halfHeight,
                                  );
                                } else {
                                  return Image.memory(
                                    imageData.imageBytes,
                                    fit: BoxFit.cover,
                                  );
                                }
                              },
                            ),
                            Align(
                              alignment: Alignment.bottomRight,
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: UserAvatar(imageData.uploadedBy,
                                    radius: 20),
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
