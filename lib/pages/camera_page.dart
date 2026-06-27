import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:native_device_orientation/native_device_orientation.dart';

import 'package:krab/services/api/supabase.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/widgets/dialogs/image_sent_dialog.dart';
import 'package:krab/widgets/dialogs/send_image_dialog.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'groups_page.dart';
import 'account_page.dart';

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
  bool _dialogOpen = false;
  SystemUiMode? _lastSystemUiMode;

  // Zoom state
  final ValueNotifier<double> _zoomNotifier = ValueNotifier(1.0);
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  // Tap focus UI
  Offset? _focusPoint;

  // User
  krab_user.User? currentUser;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initializeCamera();
    _loadCurrentUser();
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _zoomNotifier.dispose();
    _controller?.dispose();
    super.dispose();
  }

  /// Dispose camera resources
  Future<void> _disposeCamera() async {
    await _controller?.dispose();
    _controller = null;
    _initializeControllerFuture = null;
    if (mounted) setState(() {});
  }

  /// Navigate to another page, disposing camera and reinitializing on return
  Future<void> _navigateWithCameraDispose(Widget page) async {
    await _disposeCamera();
    if (!mounted) return;

    // Reset orientation to portrait
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _lastSystemUiMode = SystemUiMode.edgeToEdge;

    await Navigator.push(
      context,
      MaterialPageRoute(
        settings:
            page is GroupsPage ? const RouteSettings(name: GroupsPage.routeName) : null,
        builder: (_) => page,
      ),
    );

    if (mounted) {
      // Allow landscape mode
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      _lastSystemUiMode = null;
      await _initializeCamera();
      setState(() {});
    }
  }

  // ===== Initialization ========================================================

  Future<void> _loadCurrentUser() async {
    currentUser = await krab_user.getCurrentUser();
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
    _zoomNotifier.value = 1.0;

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

  void _onZoomChanged(double zoom) {
    _zoomNotifier.value = zoom.clamp(_minZoom, _maxZoom).toDouble();
    _controller?.setZoomLevel(_zoomNotifier.value).catchError((_) {});
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

      ctrl.setExposureOffset(0).catchError((_) {
        return 0.0;
      });

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
      showSnackBar("Error capturing image: $e");
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
      showSnackBar("Error picking image: $e");
    }
  }

  /// Delete the just-sent photo when the user taps Undo on the snackbar.
  Future<void> _undoSend(
      String imageId, String removedMsg, String failedMsg) async {
    final deleted = await deleteImage(imageId);
    if (deleted.success) {
      updateHomeWidget();
      showSnackBar(removedMsg, color: Colors.green);
    } else {
      showSnackBar(deleted.error ?? failedMsg, color: Colors.red);
    }
  }

  Future<void> _showSendImageDialog(File imageFile) async {
    setState(() => _dialogOpen = true);
    try {
      final response = await showDialog<SupabaseResponse<String>>(
        context: context,
        builder: (_) => SendImageDialog(imageFile: imageFile),
      );
      if (response == null || !mounted) return;

      if (response.success) {
        updateHomeWidget();
        // Confirm the send with a snackbar that also offers a quick Undo.
        final l10n = context.l10n;
        final imageId = response.data;
        final removedMsg = l10n.photo_removed;
        final failedMsg = l10n.failed_to_delete_photo;
        showSnackBar(
          l10n.photo_sent,
          color: Colors.green,
          actionLabel: imageId == null ? null : l10n.undo,
          onAction: imageId == null
              ? null
              : () => _undoSend(imageId, removedMsg, failedMsg),
        );
      } else {
        await showDialog(
          context: context,
          builder: (_) =>
              ImageSentDialog(success: false, errorMsg: response.error),
        );
      }
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  // ===== UI ====================================================================

  Widget _navButton({required Widget child}) => Container(
        padding: const EdgeInsets.all(2),
        decoration:
            const BoxDecoration(shape: BoxShape.circle, color: Colors.white12),
        child: child,
      );

  Widget _accountButton() {
    Future<void> onTap() async {
      await _navigateWithCameraDispose(const AccountPage());
      await _loadCurrentUser();
    }

    final hasPfp =
        currentUser?.pfpUrl != null && currentUser!.pfpUrl.isNotEmpty;
    return hasPfp
        ? GestureDetector(
            onTap: onTap, child: UserAvatar(currentUser!, radius: 24))
        : IconButton(
            icon: const Icon(Symbols.account_circle_rounded,
                color: Colors.white, size: 30),
            onPressed: onTap,
          );
  }

  Widget _shutterButton() => IconButton(
        onPressed: _takePicture,
        icon: Icon(
          Icons.circle_outlined,
          color: _captureInProgress
              ? GlobalThemeData.darkColorScheme.primary
              : Colors.white,
          size: 70,
        ),
      );

  Widget _flashButton() => IconButton(
        onPressed: _switchFlashLight,
        icon: Icon(
          _isFlashOn ? Symbols.flash_on_rounded : Symbols.flash_off_rounded,
          color: Colors.white,
        ),
      );

  Widget _flipButton() => IconButton(
        onPressed: _flipFrontBack,
        icon: const Icon(Symbols.flip_camera_android_rounded,
            color: Colors.white),
      );

  @override
  Widget build(BuildContext context) {
    return NativeDeviceOrientationReader(
      useSensor: false,
      builder: _buildContent,
    );
  }

  Widget _buildContent(BuildContext context) {
    final nativeOrientation =
        NativeDeviceOrientationReader.orientation(context);
    debugPrint("Native orientation: $nativeOrientation");

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
    if (!_dialogOpen || (isLandscape && !keyboardVisible)) {
      final targetMode =
          isLandscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge;
      if (targetMode != _lastSystemUiMode) {
        _lastSystemUiMode = targetMode;
        SystemChrome.setEnabledSystemUIMode(targetMode);
      }
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxPreviewHeight = screenHeight * (isLandscape ? 0.95 : 0.7);
    final maxPreviewWidth = screenWidth * (isLandscape ? 0.7 : 0.95);

    // The camera sensor reports a landscape aspect ratio regardless of device
    // orientation. In portrait we invert it; in landscape we use it as-is.
    final sensorAspectRatio = (_controller?.value.previewSize != null)
        ? _controller!.value.aspectRatio
        : 16 / 9;
    final displayAspectRatio =
        isLandscape ? sensorAspectRatio : (1 / sensorAspectRatio);

    double previewWidth;
    double previewHeight;

    if (maxPreviewHeight * displayAspectRatio <= maxPreviewWidth) {
      previewHeight = maxPreviewHeight;
      previewWidth = maxPreviewHeight * displayAspectRatio;
    } else {
      previewWidth = maxPreviewWidth;
      previewHeight = maxPreviewWidth / displayAspectRatio;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
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

                        final screenWidth = MediaQuery.sizeOf(context).width;
                        final screenHeight = MediaQuery.sizeOf(context).height;
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
                      onScaleStart: (_) => _baseZoom = _zoomNotifier.value,
                      onScaleUpdate: (details) {
                        if (details.scale == 1.0) return;
                        final target = (_baseZoom * details.scale)
                            .clamp(_minZoom, _maxZoom)
                            .toDouble();
                        _onZoomChanged(target);
                      },
                      onScaleEnd: (_) => _onZoomChanged(_zoomNotifier.value),
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
                Positioned(
                  top: MediaQuery.sizeOf(context).height * 0.15,
                  left: MediaQuery.sizeOf(context).width / 2 - 30,
                  child: ValueListenableBuilder<double>(
                    valueListenable: _zoomNotifier,
                    builder: (context, zoom, _) {
                      if (zoom <= 1.01) return const SizedBox.shrink();
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${zoom.toStringAsFixed(1)}x',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16),
                        ),
                      );
                    },
                  ),
                ),

                // Nav buttons: physical top of phone
                if (isLandscape)
                  Positioned(
                    left: nativeOrientation ==
                            NativeDeviceOrientation.landscapeLeft
                        ? 10
                        : null,
                    right: nativeOrientation ==
                            NativeDeviceOrientation.landscapeLeft
                        ? null
                        : 10,
                    top: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _navButton(child: _accountButton()),
                        const SizedBox(height: 8),
                        _navButton(
                            child: IconButton(
                          icon: const Icon(Symbols.upload_rounded,
                              color: Colors.white, size: 30),
                          onPressed: _sendPictureFromStorage,
                        )),
                        const SizedBox(height: 8),
                        _navButton(
                            child: IconButton(
                          icon: const Icon(Symbols.group_rounded,
                              color: Colors.white, size: 30),
                          onPressed: () =>
                              _navigateWithCameraDispose(const GroupsPage()),
                        )),
                      ],
                    ),
                  )
                else ...[
                  Positioned(
                    top: 50,
                    left: 25,
                    child: _navButton(
                        child: IconButton(
                      icon: const Icon(Symbols.group_rounded,
                          color: Colors.white, size: 30),
                      onPressed: () =>
                          _navigateWithCameraDispose(const GroupsPage()),
                    )),
                  ),
                  Positioned(
                    top: 50,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: _navButton(
                          child: IconButton(
                        icon: const Icon(Symbols.upload_rounded,
                            color: Colors.white, size: 30),
                        onPressed: _sendPictureFromStorage,
                      )),
                    ),
                  ),
                  Positioned(
                    top: 50,
                    right: 25,
                    child: _navButton(child: _accountButton()),
                  ),
                ],

                // Shutter buttons: physical bottom of phone
                if (isLandscape)
                  Positioned(
                    left: nativeOrientation ==
                            NativeDeviceOrientation.landscapeLeft
                        ? null
                        : 10,
                    right: nativeOrientation ==
                            NativeDeviceOrientation.landscapeLeft
                        ? 10
                        : null,
                    top: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _flipButton(),
                        _shutterButton(),
                        _flashButton()
                      ],
                    ),
                  )
                else
                  Positioned(
                    bottom: 20,
                    left: 0,
                    right: 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _flashButton(),
                        _shutterButton(),
                        _flipButton()
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
