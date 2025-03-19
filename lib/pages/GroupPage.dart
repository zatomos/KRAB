import 'dart:typed_data';
import 'package:flutter/material.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/models/Group.dart';
import 'package:krab/pages/GroupSettingsPage.dart';
import 'package:krab/widgets/UserAvatar.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
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

  @override
  void initState() {
    super.initState();
    _groupImagesFuture = getGroupImages(widget.group.id);
    _checkAdminStatus();
  }

  /// Check if the user is an admin of this group.
  Future<void> _checkAdminStatus() async {
    final adminStatus = await isAdmin(widget.group.id);
    if (adminStatus.success) {
      setState(() {
        _isAdmin = adminStatus.data!;
      });
    }
  }

  void _showImagePreview(String imageId) async {
    try {
      // Retrieve image bytes
      final imageResponse = await getImage(imageId);
      if (!imageResponse.success || imageResponse.data == null) {
        throw Exception("Error downloading image: ${imageResponse.error}");
      }
      final Uint8List imageBytes = imageResponse.data!;

      // Retrieve image details
      final imageDetailsResponse = await getImageDetails(imageId);
      if (!imageDetailsResponse.success || imageDetailsResponse.data == null) {
        throw Exception("Error fetching image details: ${imageDetailsResponse.error}");
      }
      final Map<String, dynamic> imageDetails = imageDetailsResponse.data!;

      // Retrieve uploader's username
      final usernameResponse = await getUsername(imageDetails['uploaded_by']);
      if (!usernameResponse.success || usernameResponse.data == null) {
        throw Exception("Error fetching username: ${usernameResponse.error}");
      }
      final String uploadedBy = usernameResponse.data!;

      showDialog(
        context: context,
        builder: (context) {
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
                        // Display Image
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: FittedBox(
                            fit: BoxFit.contain, // Ensures image scales within constraints
                            child: Image.memory(imageBytes),
                          ),
                        ),

                        // Download Button
                        Positioned(
                          top: 10,
                          right: 10,
                          child: IconButton(
                            icon: const Icon(Icons.download, color: Colors.white),
                            onPressed: () async {
                              await downloadImage(
                                  imageBytes,
                                  uploadedBy,
                                  imageDetails['created_at']);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    title: Text(
                      uploadedBy,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      imageDetails['description'] ?? "",
                      style: TextStyle(
                          color: GlobalThemeData.darkColorScheme.onSurfaceVariant),
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
        },
      );
    } catch (error) {
      debugPrint("Error fetching image details: $error");
      showSnackBar(context, "Error fetching image details: $error", color: Colors.red);
    }
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
              child: Text("Error loading images: ${snapshot.error}"),
            );
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
                crossAxisCount: 2, // Two columns
                crossAxisSpacing: 4.0,
                mainAxisSpacing: 4.0,
                childAspectRatio: 1, // Ensures square images
              ),
              itemBuilder: (context, index) {
                final image = images[index];
                final imageId = image['id'].toString();
                final uploadedBy = image['uploaded_by']; // User ID

                return GestureDetector(
                  onTap: () => _showImagePreview(imageId),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand, // Ensures full coverage
                      children: [
                        FutureBuilder<SupabaseResponse<Uint8List>>(
                          future: getImage(imageId),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return Container(
                                color: Colors.grey[300],
                                child: const Center(child: CircularProgressIndicator()),
                              );
                            }
                            if (!snapshot.hasData ||
                                !snapshot.data!.success ||
                                snapshot.data!.data == null) {
                              return Container(
                                color: Colors.grey,
                                child: const Icon(Icons.error, size: 50),
                              );
                            }
                            final imageBytes = snapshot.data!.data!;
                            return Image.memory(
                              imageBytes,
                              fit: BoxFit.cover, // Fills the grid item
                            );
                          },
                        ),
                        Align(
                          alignment: Alignment.bottomRight,
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: FutureBuilder<SupabaseResponse<String>>(
                              future: getUsername(uploadedBy),
                              builder: (context, usernameSnapshot) {
                                if (usernameSnapshot.connectionState == ConnectionState.waiting) {
                                  return const CircleAvatar(
                                    radius: 20,
                                    backgroundColor: Colors.white10,
                                  );
                                }
                                if (!usernameSnapshot.hasData ||
                                    !usernameSnapshot.data!.success ||
                                    usernameSnapshot.data!.data == null) {
                                  return const CircleAvatar(
                                    radius: 20,
                                    backgroundColor: Colors.white,
                                    child: Icon(Icons.error, size: 20),
                                  );
                                }
                                final username = usernameSnapshot.data!.data!;
                                return UserAvatar(username, radius: 20);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
