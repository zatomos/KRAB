import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/UserPreferences.dart';
import 'GroupsPage.dart';
import 'AccountPage.dart';

class ImageSentDialog extends StatelessWidget {
  final bool success;
  final String? errorMsg;

  const ImageSentDialog({super.key, required this.success, this.errorMsg});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(success ? "Image Sent" : "Error Sending Image"),
      content: Text(success
          ? "Your image has been sent to the selected groups."
          : "There was an error sending your image: $errorMsg"),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text("OK"),
        ),
      ],
    );
  }
}

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  CameraPageState createState() => CameraPageState();
}

class CameraPageState extends State<CameraPage> {
  CameraController? _controller;
  Future<void>? _initializeControllerFuture;
  List<CameraDescription>? _cameras;
  int _selectedCameraIndex = 0;
  bool _isFlashOn = false;
  bool _captureInProgress = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    // Check if camera permission is granted.
    final cameraPermissionStatus = await Permission.camera.status;
    if (!cameraPermissionStatus.isGranted) {
      final result = await Permission.camera.request();
      if (!result.isGranted) {
        debugPrint("Camera permission not granted");
        return;
      }
    }

    try {
      _cameras = await availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        _controller = CameraController(
          _cameras![_selectedCameraIndex],
          ResolutionPreset.high,
        );
        _initializeControllerFuture = _controller!.initialize();
        await _initializeControllerFuture;
        await _controller!.setExposureMode(ExposureMode.auto);
        await _controller!.setFocusMode(FocusMode.auto);
        if (mounted) setState(() {});
      } else {
        debugPrint("No cameras available");
      }
    } catch (e) {
      debugPrint("Error during camera initialization: $e");
    }
  }

  Future<void> _switchFlashLight() async {
    if (_controller == null) return;
    _isFlashOn = !_isFlashOn;
    await _controller!
        .setFlashMode(_isFlashOn ? FlashMode.torch : FlashMode.off);
    setState(() {});
  }

  Future<void> _switchCamera() async {
    if (_cameras == null || _cameras!.isEmpty) return;
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras!.length;
    await _controller?.dispose();
    _controller = CameraController(
      _cameras![_selectedCameraIndex],
      ResolutionPreset.high,
    );
    _initializeControllerFuture = _controller!.initialize();
    await _initializeControllerFuture;
    setState(() {});
  }

  Future<void> _takePicture() async {
    try {
      // Prevent multiple captures
      if (_captureInProgress) return;

      if (mounted) setState(() => _captureInProgress = true);

      // Capture the image
      final image = await _controller!.takePicture();
      await _showSendImageDialog(File(image.path));

      if (mounted) setState(() => _captureInProgress = false);

    } catch (e) {
      debugPrint("Error capturing image: $e");
      showSnackBar(context, "Error capturing image: $e");
      if (mounted) setState(() => _captureInProgress = false);
    }
  }

  Future<void> _sendPictureFromStorage() async {
    try {
      // Create an instance of ImagePickerAndroid
      final ImagePicker imagePicker = ImagePicker();

      // Pick an image from the gallery
      final XFile? pickedImage =
          await imagePicker.pickImage(source: ImageSource.gallery);

      // User canceled the picker
      if (pickedImage == null) {
        debugPrint("No image selected");
        return;
      }

      final File imageFile = File(pickedImage.path);

      // Show the send image dialog
      await _showSendImageDialog(imageFile);
    } catch (e) {
      debugPrint("Error picking image: $e");
      showSnackBar(context, "Error picking image: $e");
    }
  }

  Future<void> _showSendImageDialog(File imageFile) async {
    final TextEditingController description = TextEditingController();
    final favoriteGroups = await UserPreferences.getFavoriteGroups();
    Set<String> selectedGroups = {};

    // Pre-select favorite groups
    selectedGroups.addAll(favoriteGroups);

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              title: const Text("Select Groups"),
              content: Container(
                width: MediaQuery.of(context).size.width * 0.9,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Image preview
                      Container(
                        width: double.infinity,
                        height: 200,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          image: DecorationImage(
                            image: FileImage(imageFile),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Load groups asynchronously using FutureBuilder.
                      FutureBuilder(
                        future: getUserGroups(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            // Show a loading indicator while waiting.
                            return const Padding(padding: EdgeInsets.all(30), child: CircularProgressIndicator());
                          } else if (snapshot.hasError ||
                              !snapshot.hasData ||
                              !(snapshot.data?.success ?? false)) {
                            // If there's an error or no groups available, display an error message.
                            final errorMsg = snapshot.hasError
                                ? snapshot.error.toString()
                                : (snapshot.data?.error ?? "Failed to load groups");
                            return Center(child: Text("Error: $errorMsg"));
                          } else {
                            final groups = snapshot.data!.data ?? [];
                            if (groups.isEmpty) {
                              return const Center(child: Text("Please join a group first!"));
                            } else {
                              return SizedBox(
                                height: 200,
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: groups.length,
                                  itemBuilder: (context, index) {
                                    final group = groups[index];
                                    return CheckboxListTile(
                                      title: Text(group.name),
                                      value: selectedGroups.contains(group.id),
                                      onChanged: (bool? value) {
                                        setState(() {
                                          if (value == true) {
                                            selectedGroups.add(group.id);
                                          } else {
                                            selectedGroups.remove(group.id);
                                          }
                                        });
                                      },
                                    );
                                  },
                                ),
                              );
                            }
                          }
                        },
                      ),
                      const SizedBox(height: 10),
                      // Description input field
                      RoundedInputField(
                        hintText: "Add a description...",
                        controller: description,
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("Cancel"),
                ),
                TextButton(
                  onPressed: () async {
                    if (selectedGroups.isEmpty) {
                      await showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text("Error"),
                          content: const Text("Please select at least one group."),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text("OK"),
                            ),
                          ],
                        ),
                      );
                      return;
                    }
                    final response = await sendImageToGroups(
                      imageFile,
                      selectedGroups.toList(),
                      description.text,
                    );
                    Navigator.of(context).pop();
                    await showDialog(
                      context: context,
                      builder: (context) => ImageSentDialog(
                        success: response.success,
                        errorMsg: response.error,
                      ),
                    );
                  },
                  child: const Text("Send"),
                ),
              ],
            );
          },
        );
      },
    );
  }


  @override
  Widget build(BuildContext context) {
    final previewHeight = MediaQuery.of(context).size.height * 0.7;
    final previewWidth = previewHeight / (_controller?.value.aspectRatio ?? 1);

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              children: [
                Positioned.fill(
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        width: previewWidth,
                        height: previewHeight,
                        color: Colors.white12,
                        child: CameraPreview(_controller!),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 50,
                  left: 25,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white12,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.group,
                          color: Colors.white, size: 30),
                      onPressed: () {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const GroupsPage()));
                      },
                    ),
                  ),
                ),
                Positioned(
                  top: 50,
                  right: MediaQuery.of(context).size.width / 2 - 30,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white12,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.photo_rounded,
                          color: Colors.white, size: 30),
                      onPressed: () {
                        _sendPictureFromStorage();
                      },
                    ),
                  ),
                ),
                Positioned(
                    top: 50,
                    right: 25,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white12,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.account_circle_rounded,
                            color: Colors.white, size: 30),
                        onPressed: () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const AccountPage()));
                        },
                      ),
                    )),
                Positioned(
                  bottom: 20,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: _switchFlashLight,
                        icon: Icon(
                          _isFlashOn ? Icons.flash_on : Icons.flash_off,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        onPressed: _takePicture,
                        icon: Icon(
                          Icons.circle_outlined,
                          color: (_captureInProgress
                              ? GlobalThemeData.darkColorScheme.primary
                              : Colors.white),
                          size: 70,
                        ),
                      ),
                      IconButton(
                        onPressed: _switchCamera,
                        icon: const Icon(Icons.flip_camera_android_rounded,
                            color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            );
          } else if (snapshot.hasError) {
            return Center(
              child: Text(
                "Error initializing camera: ${snapshot.error}",
                style: const TextStyle(color: Colors.white),
              ),
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}
