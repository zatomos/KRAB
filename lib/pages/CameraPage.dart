import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/models/User.dart' as KRAB_User;
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/widgets/UserAvatar.dart';
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
      title: Text(success
          ? context.l10n.image_sent_title
          : context.l10n.error_image_not_sent_title),
      content: Text(success
          ? context.l10n.image_sent_subtitle
          : context.l10n
              .error_image_not_sent_subtitle(errorMsg ?? 'Unknown error')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
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

  // Zoom state
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _desiredZoom = 1.0;
  Timer? _zoomTimer;
  bool _zoomApplying = false;
  final Duration _zoomPeriod = const Duration(milliseconds: 16); // ~60fps

  // Tap focus UI
  Offset? _focusPoint;

  // User
  KRAB_User.User? currentUser;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadCurrentUser();
  }

  @override
  void dispose() {
    _zoomTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // ===== Initialization ========================================================

  Future<void> _loadCurrentUser() async {
    currentUser = await KRAB_User.getCurrentUser();
    debugPrint("Loaded current user: $currentUser");
  }

  Future<void> _initializeCamera() async {
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
      if (_cameras == null || _cameras!.isEmpty) {
        debugPrint("No cameras available");
        return;
      }

      debugPrint("Raw cameras from platform:");
      for (var i = 0; i < _cameras!.length; i++) {
        final c = _cameras![i];
        debugPrint(
            "  [$i] name='${c.name}' direction=${c.lensDirection} orientation=${c.sensorOrientation}");
      }

      // Prefer back camera if present, otherwise index 0.
      final backIndex = _cameras!
          .indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      _selectedCameraIndex = backIndex != -1 ? backIndex : 0;

      await _createControllerForIndex(_selectedCameraIndex);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Error during camera initialization: $e");
    }
  }

  Future<void> _createControllerForIndex(int cameraIndex) async {
    final cams = _cameras;
    if (cams == null || cameraIndex < 0 || cameraIndex >= cams.length) {
      debugPrint("Invalid camera index: $cameraIndex");
      return;
    }

    debugPrint("Creating controller for camera[$cameraIndex]: "
        "${cams[cameraIndex].name} (${cams[cameraIndex].lensDirection})");

    _controller?.dispose();
    _controller = CameraController(
      cams[cameraIndex],
      ResolutionPreset.ultraHigh,
      enableAudio: false,
    );
    _initializeControllerFuture = _controller!.initialize();
    await _initializeControllerFuture;

    try {
      await _controller!.setFocusMode(FocusMode.auto);
    } catch (e) {
      debugPrint("setFocusMode unsupported: $e");
    }
    try {
      await _controller!.setExposureMode(ExposureMode.auto);
    } catch (e) {
      debugPrint("setExposureMode unsupported: $e");
    }

    _minZoom = await _controller!.getMinZoomLevel();
    _maxZoom = await _controller!.getMaxZoomLevel();
    _currentZoom = 1.0;
    _desiredZoom = 1.0;

    debugPrint("Zoom caps: min=$_minZoom max=$_maxZoom");
  }

  // ===== Flash, camera switching, zoom, focus/AE ===============================

  Future<void> _switchFlashLight() async {
    if (_controller == null) return;
    _isFlashOn = !_isFlashOn;
    await _controller!
        .setFlashMode(_isFlashOn ? FlashMode.torch : FlashMode.off);
    if (mounted) setState(() {});
  }

  Future<void> _flipFrontBack() async {
    if (_cameras == null || _cameras!.isEmpty) return;

    final current = _cameras![_selectedCameraIndex];
    final targetDir = current.lensDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;

    final targetIndex =
        _cameras!.indexWhere((c) => c.lensDirection == targetDir);
    if (targetIndex == -1) {
      debugPrint("No camera with direction=$targetDir");
      return;
    }

    debugPrint(
        "Switching to camera[$targetIndex] (${_cameras![targetIndex].lensDirection})");
    _selectedCameraIndex = targetIndex;
    await _createControllerForIndex(targetIndex);
    if (mounted) setState(() {});
  }

  void _scheduleZoomApply() {
    _zoomTimer ??= Timer(_zoomPeriod, () async {
      _zoomTimer = null;
      final ctrl = _controller;
      if (ctrl == null || !ctrl.value.isInitialized) return;

      if (_zoomApplying) {
        _scheduleZoomApply();
        return;
      }

      _zoomApplying = true;
      final double toApply = _desiredZoom;
      try {
        await ctrl.setZoomLevel(toApply);
      } catch (e) {
        debugPrint("setZoomLevel failed: $e");
      } finally {
        _zoomApplying = false;
        if ((toApply - _desiredZoom).abs() > 1e-3) _scheduleZoomApply();
      }
    });
  }

  Future<void> _onZoomChanged(double zoom) async {
    _desiredZoom = zoom.clamp(_minZoom, _maxZoom).toDouble();
    if (mounted) setState(() => _currentZoom = _desiredZoom);
    _scheduleZoomApply();
  }

  Future<void> _setFocusPoint(Offset point, Size previewSize) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    if (mounted) setState(() => _focusPoint = point);

    // Normalize
    double x = point.dx / previewSize.width;
    double y = point.dy / previewSize.height;

    // Flip X for front
    final isFront = _cameras != null &&
        _cameras!.isNotEmpty &&
        _cameras![_selectedCameraIndex].lensDirection ==
            CameraLensDirection.front;
    if (isFront) x = 1.0 - x;

    try {
      // Always stay in auto
      if (ctrl.value.focusMode != FocusMode.auto) {
        try {
          await ctrl.setFocusMode(FocusMode.auto);
        } catch (e) {
          debugPrint("setFocusMode(auto) failed: $e");
        }
      }
      if (ctrl.value.exposureMode != ExposureMode.auto) {
        try {
          await ctrl.setExposureMode(ExposureMode.auto);
        } catch (e) {
          debugPrint("setExposureMode(auto) failed: $e");
        }
      }

      ctrl.setExposureOffset(0).catchError((_) {});

      await ctrl.setFocusPoint(Offset(x, y));
      await ctrl.setExposurePoint(Offset(x, y));

      // Small delay before returning to auto modes
      await Future.delayed(const Duration(milliseconds: 180));
      try {
        await ctrl.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await ctrl.setExposureMode(ExposureMode.auto);
      } catch (_) {}
    } catch (e) {
      debugPrint("Error setting focus/exposure point: $e");
      try {
        await ctrl.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await ctrl.setExposureMode(ExposureMode.auto);
      } catch (_) {}
    }

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusPoint = null);
    });
  }

  // ===== Capture & gallery =====================================================

  Future<void> _takePicture() async {
    try {
      if (_captureInProgress) return;
      if (mounted) setState(() => _captureInProgress = true);

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
      final ImagePicker imagePicker = ImagePicker();
      final XFile? pickedImage =
          await imagePicker.pickImage(source: ImageSource.gallery);
      if (pickedImage == null) {
        debugPrint("No image selected");
        return;
      }
      final File imageFile = File(pickedImage.path);
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
    selectedGroups.addAll(favoriteGroups);
    final groupsFuture = getUserGroups();

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              title: Text(context.l10n.select_groups),
              content: Container(
                width: MediaQuery.of(context).size.width * 0.9,
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.8),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: double.infinity,
                        height: 200,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          image: DecorationImage(
                              image: FileImage(imageFile), fit: BoxFit.cover),
                        ),
                      ),
                      const SizedBox(height: 10),
                      FutureBuilder(
                        future: groupsFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Padding(
                              padding: EdgeInsets.all(30),
                              child: CircularProgressIndicator(),
                            );
                          } else if (snapshot.hasError ||
                              !snapshot.hasData ||
                              !(snapshot.data?.success ?? false)) {
                            final errorMsg = snapshot.hasError
                                ? snapshot.error.toString()
                                : (snapshot.data?.error ??
                                    context.l10n.failed_to_load_groups);
                            return Center(child: Text("Error: $errorMsg"));
                          } else {
                            final groups = snapshot.data!.data ?? [];
                            if (groups.isEmpty) {
                              return Center(
                                  child: Text(context.l10n.join_group_first));
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
                      RoundedInputField(
                          hintText: context.l10n.add_description,
                          capitalizeSentences: true,
                          controller: description),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(context.l10n.cancel)),
                TextButton(
                    onPressed: () async {
                      if (selectedGroups.isEmpty) {
                        await showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(context.l10n.error),
                            content:
                                Text(context.l10n.select_at_least_one_group),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text("OK")),
                            ],
                          ),
                        );
                        return;
                      }

                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (context) =>
                            const Center(child: CircularProgressIndicator()),
                      );

                      final response = await sendImageToGroups(
                        imageFile,
                        selectedGroups.toList(),
                        description.text,
                      );

                      Navigator.of(context).pop(); // loading
                      Navigator.of(context).pop(); // main dialog

                      await showDialog(
                        context: context,
                        builder: (context) => ImageSentDialog(
                          success: response.success,
                          errorMsg: response.error,
                        ),
                      );
                    },
                    child: Text(context.l10n.send)),
              ],
            );
          },
        );
      },
    );
  }

  // ===== UI ====================================================================

  @override
  Widget build(BuildContext context) {
    final maxPreviewHeight = MediaQuery.of(context).size.height * 0.7;
    final maxPreviewWidth = MediaQuery.of(context).size.width * 0.9;
    final aspectRatio = _controller?.value.aspectRatio ?? 16 / 9;
    final portraitAspectRatio = 1 / aspectRatio;

    double previewWidth;
    double previewHeight;

    if (maxPreviewHeight * portraitAspectRatio <= maxPreviewWidth) {
      previewHeight = maxPreviewHeight;
      previewWidth = maxPreviewHeight * portraitAspectRatio;
    } else {
      previewWidth = maxPreviewWidth;
      previewHeight = maxPreviewWidth / portraitAspectRatio;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              _controller != null &&
              _controller!.value.isInitialized) {
            return Stack(
              children: [
                // Preview + gestures
                Positioned.fill(
                  child: Center(
                    child: GestureDetector(
                      onTapDown: (details) {
                        final RenderBox box =
                            context.findRenderObject() as RenderBox;
                        final Offset localPosition =
                            box.globalToLocal(details.globalPosition);

                        final screenWidth = MediaQuery.of(context).size.width;
                        final screenHeight = MediaQuery.of(context).size.height;
                        final previewLeft = (screenWidth - previewWidth) / 2;
                        final previewTop = (screenHeight - previewHeight) / 2;

                        if (localPosition.dx >= previewLeft &&
                            localPosition.dx <= previewLeft + previewWidth &&
                            localPosition.dy >= previewTop &&
                            localPosition.dy <= previewTop + previewHeight) {
                          final relativePosition = Offset(
                            localPosition.dx - previewLeft,
                            localPosition.dy - previewTop,
                          );
                          _setFocusPoint(relativePosition,
                              Size(previewWidth, previewHeight));
                        }
                      },
                      onScaleStart: (_) => _baseZoom = _currentZoom,
                      onScaleUpdate: (details) {
                        if (details.scale == 1.0) return;
                        final target = (_baseZoom * details.scale)
                            .clamp(_minZoom, _maxZoom)
                            .toDouble();
                        _onZoomChanged(target);
                      },
                      onScaleEnd: (_) => _onZoomChanged(_currentZoom),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              width: previewWidth,
                              height: previewHeight,
                              color: Colors.white12,
                              child: CameraPreview(_controller!),
                            ),
                          ),
                          if (_focusPoint != null)
                            Positioned(
                              left: _focusPoint!.dx - 40,
                              top: _focusPoint!.dy - 40,
                              child: AnimatedOpacity(
                                opacity: 1.0,
                                duration: const Duration(milliseconds: 80),
                                child: Container(
                                  width: 80,
                                  height: 80,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: Colors.white, width: 2),
                                    borderRadius: BorderRadius.circular(40),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Zoom HUD
                if (_currentZoom > 1.01)
                  Positioned(
                    top: MediaQuery.of(context).size.height * 0.15,
                    left: MediaQuery.of(context).size.width / 2 - 30,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_currentZoom.toStringAsFixed(_currentZoom < 1 ? 1 : 1)}x',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ),

                // Top buttons
                Positioned(
                  top: 50,
                  left: 25,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Colors.white12),
                    child: IconButton(
                      icon: const Icon(Icons.group_rounded,
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
                        shape: BoxShape.circle, color: Colors.white12),
                    child: IconButton(
                      icon: const Icon(Icons.upload_rounded,
                          color: Colors.white, size: 30),
                      onPressed: _sendPictureFromStorage,
                    ),
                  ),
                ),
                Positioned(
                  top: 50,
                  right: 25,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Colors.white12),
                    child: currentUser?.pfpUrl != null &&
                            currentUser!.pfpUrl.isNotEmpty
                        ? GestureDetector(
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const AccountPage()),
                              );

                              // After returning, reload user data
                              await _loadCurrentUser();
                              if (mounted) setState(() {});
                            },
                            child: UserAvatar(currentUser!, radius: 24),
                          )
                        : IconButton(
                            icon: const Icon(
                              Icons.account_circle_rounded,
                              color: Colors.white,
                              size: 30,
                            ),
                            onPressed: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const AccountPage()),
                              );

                              // After returning, reload user data
                              await _loadCurrentUser();
                              if (mounted) setState(() {});
                            },
                          ),
                  ),
                ),

                // Shutter row
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
                            color: Colors.white),
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
                      // Flip front/back
                      IconButton(
                        onPressed: _flipFrontBack,
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
              child: Text("Error initializing camera: ${snapshot.error}",
                  style: const TextStyle(color: Colors.white)),
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}
