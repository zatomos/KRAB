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
import 'package:path_provider/path_provider.dart';

import 'package:krab/services/api/supabase.dart';
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

/// Portrait only, for the pages the camera navigates to.
void _lockPortrait() => SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

/// The camera itself shoots in any orientation.
void _allowAllOrientations() => SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

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
    _allowAllOrientations();
    _initializeCamera();
    _loadCurrentUser();
  }

  @override
  void dispose() {
    _lockPortrait();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _zoomNotifier.dispose();
    _controller?.dispose();
    super.dispose();
  }

  /// Dispose camera resources
  Future<void> _disposeCamera() async {
    // Detach the controller and rebuild first, so the live CameraPreview leaves
    // the tree before we dispose it.
    final controller = _controller;
    _controller = null;
    _initializeControllerFuture = null;
    if (mounted) setState(() {});
    await controller?.dispose();
  }

  /// Navigate to another page, disposing camera and reinitializing on return
  Future<void> _navigateWithCameraDispose(Widget page) async {
    await _disposeCamera();
    if (!mounted) return;

    _lockPortrait();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _lastSystemUiMode = SystemUiMode.edgeToEdge;

    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: page is GroupsPage
            ? const RouteSettings(name: GroupsPage.routeName)
            : null,
        builder: (_) => page,
      ),
    );

    if (mounted) {
      _allowAllOrientations();
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

    // Tear the old preview out of the tree before disposing its controller
    final previous = _controller;
    _controller = null;
    if (mounted) setState(() {});
    await previous?.dispose();

    _controller = CameraController(
      cams[cameraIndex],
      ResolutionPreset.ultraHigh,
      enableAudio: false,
    );
    _initializeControllerFuture = _controller!.initialize();
    await _initializeControllerFuture;

    await _resetToAutoModes(_controller!);

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

  /// Put focus and exposure back on auto. Either may be unsupported.
  Future<void> _resetToAutoModes(CameraController ctrl) async {
    try {
      await ctrl.setFocusMode(FocusMode.auto);
    } catch (e) {
      debugPrint("setFocusMode(auto) failed: $e");
    }
    try {
      await ctrl.setExposureMode(ExposureMode.auto);
    } catch (e) {
      debugPrint("setExposureMode(auto) failed: $e");
    }
  }

  Future<void> _setFocusPoint(Offset point, Size previewSize) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    if (mounted) setState(() => _focusPoint = point);

    double x = point.dx / previewSize.width;
    final y = point.dy / previewSize.height;

    // The front camera's preview is mirrored, so its x is too.
    final isFront = _cameras != null &&
        _cameras!.isNotEmpty &&
        _cameras![_selectedCameraIndex].lensDirection ==
            CameraLensDirection.front;
    if (isFront) x = 1.0 - x;

    try {
      await _resetToAutoModes(ctrl);
      ctrl.setExposureOffset(0).catchError((_) => 0.0);

      await ctrl.setFocusPoint(Offset(x, y));
      await ctrl.setExposurePoint(Offset(x, y));

      // Small delay before returning to auto modes
      await Future.delayed(const Duration(milliseconds: 180));
    } catch (e) {
      debugPrint("Error setting focus/exposure point: $e");
    }
    await _resetToAutoModes(ctrl);

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusPoint = null);
    });
  }

  // ===== Capture & gallery =====================================================

  Future<void> _takePicture() async {
    final errorMessage = context.l10n.error_capturing_image;
    try {
      if (_captureInProgress) return;
      if (mounted) setState(() => _captureInProgress = true);

      final image = await _controller!.takePicture();
      await _showSendImageDialog(File(image.path));

      if (mounted) setState(() => _captureInProgress = false);
    } catch (e) {
      debugPrint("Error capturing image: $e");
      showSnackBar(errorMessage, tone: SnackTone.failure);
      if (mounted) setState(() => _captureInProgress = false);
    }
  }

  Future<void> _sendPictureFromStorage() async {
    final errorMessage = context.l10n.error_picking_image;
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
      showSnackBar(errorMessage, tone: SnackTone.failure);
    }
  }

  /// Delete the just-sent photo when the user taps Undo on the snackbar.
  Future<void> _undoSend(
      String imageId, String removedMsg, String failedMsg) async {
    final deleted = await deleteImage(imageId);
    if (deleted.success) {
      updateHomeWidget();
      showSnackBar(removedMsg, tone: SnackTone.success);
    } else {
      showSnackBar(failedMsg, tone: SnackTone.failure);
    }
  }

  /// Delete a capture once the send dialog is done with it.
  Future<void> _discardCapture(File imageFile) async {
    try {
      final temp = await getTemporaryDirectory();
      if (!imageFile.path.startsWith(temp.path)) {
        debugPrint(
            "Not deleting ${imageFile.path}: outside the temp directory");
        return;
      }
      if (await imageFile.exists()) await imageFile.delete();
    } catch (e) {
      debugPrint("Could not delete the capture: $e");
    }
  }

  Future<void> _showSendImageDialog(File imageFile) async {
    setState(() => _dialogOpen = true);
    try {
      final result = await showDialog<SendImageResult>(
        context: context,
        builder: (_) => SendImageDialog(imageFile: imageFile),
      );
      if (result == null || !mounted) return;

      final l10n = context.l10n;

      switch (result.outcome) {
        case SendOutcome.sent:
          updateHomeWidget();
          // Confirm the send with a snackbar that also offers a quick Undo.
          final imageId = result.imageId;
          final removedMsg = l10n.photo_removed;
          final failedMsg = l10n.failed_to_delete_photo;
          showSnackBar(
            l10n.photo_sent,
            tone: SnackTone.success,
            actionLabel: imageId == null ? null : l10n.undo,
            onAction: imageId == null
                ? null
                : () => _undoSend(imageId, removedMsg, failedMsg),
          );
        case SendOutcome.queued:
          // The photo is safe in the outbox, so this reads as a success.
          showSnackBar(l10n.photo_queued_offline, tone: SnackTone.success);
        case SendOutcome.failed:
          await showDialog(
            context: context,
            builder: (_) => ImageSentDialog(
                success: false, errorMsg: context.errorText(result.error)),
          );
      }
    } finally {
      await _discardCapture(imageFile);
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
              ? Theme.of(context).colorScheme.primary
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

  /// The largest preview that fits the screen at the sensor's aspect ratio.
  Size _previewSize(BuildContext context, {required bool isLandscape}) {
    final screen = MediaQuery.sizeOf(context);
    final maxHeight = screen.height * (isLandscape ? 0.95 : 0.7);
    final maxWidth = screen.width * (isLandscape ? 0.7 : 0.95);

    final sensorRatio = _controller?.value.previewSize != null
        ? _controller!.value.aspectRatio
        : 16 / 9;
    final ratio = isLandscape ? sensorRatio : 1 / sensorRatio;

    return maxHeight * ratio <= maxWidth
        ? Size(maxHeight * ratio, maxHeight)
        : Size(maxWidth, maxWidth / ratio);
  }

  /// The live preview, with tap-to-focus and pinch-to-zoom over it.
  Widget _preview(Size size) {
    return GestureDetector(
      onTapDown: (details) => _onPreviewTap(details, size),
      onScaleStart: (_) => _baseZoom = _zoomNotifier.value,
      onScaleUpdate: (details) {
        if (details.scale == 1.0) return;
        _onZoomChanged(_baseZoom * details.scale);
      },
      onScaleEnd: (_) => _onZoomChanged(_zoomNotifier.value),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Container(
              width: size.width,
              height: size.height,
              color: Colors.white12,
              child: CameraPreview(_controller!),
            ),
          ),
          if (_focusPoint != null)
            Positioned(
              left: _focusPoint!.dx - _focusRingRadius,
              top: _focusPoint!.dy - _focusRingRadius,
              child: Container(
                width: _focusRingRadius * 2,
                height: _focusRingRadius * 2,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static const double _focusRingRadius = 40;

  /// Focus where the user tapped.
  void _onPreviewTap(TapDownDetails details, Size preview) {
    final box = context.findRenderObject() as RenderBox;
    final local = box.globalToLocal(details.globalPosition);

    final screen = MediaQuery.sizeOf(context);
    final origin = Offset(
      (screen.width - preview.width) / 2,
      (screen.height - preview.height) / 2,
    );
    final inPreview = local.dx >= origin.dx &&
        local.dx <= origin.dx + preview.width &&
        local.dy >= origin.dy &&
        local.dy <= origin.dy + preview.height;
    if (!inPreview) return;

    _setFocusPoint(local - origin, preview);
  }

  /// The zoom readout, shown only while zoomed in.
  Widget _zoomHud(BuildContext context) {
    return Positioned(
      top: MediaQuery.sizeOf(context).height * 0.15,
      left: MediaQuery.sizeOf(context).width / 2 - 30,
      child: ValueListenableBuilder<double>(
        valueListenable: _zoomNotifier,
        builder: (context, zoom, _) {
          if (zoom <= 1.01) return const SizedBox.shrink();
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${zoom.toStringAsFixed(1)}x',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          );
        },
      ),
    );
  }

  /// Position buttons correctly depending on the phone orientation.
  Widget _landscapeStrip({
    required List<Widget> items,
    required bool isLandscapeLeft,
    required bool physicalTop,
  }) {
    final onLeftEdge = physicalTop == isLandscapeLeft;
    return Positioned(
      left: onLeftEdge ? 10 : null,
      right: onLeftEdge ? null : 10,
      top: 0,
      bottom: 0,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: isLandscapeLeft ? items.reversed.toList() : items,
      ),
    );
  }

  Widget _groupsButton() => IconButton(
        icon: const Icon(Symbols.group_rounded, color: Colors.white, size: 30),
        onPressed: () => _navigateWithCameraDispose(const GroupsPage()),
      );

  Widget _uploadButton() => IconButton(
        icon: const Icon(Symbols.upload_rounded, color: Colors.white, size: 30),
        onPressed: _sendPictureFromStorage,
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
    final isLandscapeLeft =
        nativeOrientation == NativeDeviceOrientation.landscapeLeft;
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
    if (!_dialogOpen || (isLandscape && !keyboardVisible)) {
      final targetMode =
          isLandscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge;
      if (targetMode != _lastSystemUiMode) {
        _lastSystemUiMode = targetMode;
        SystemChrome.setEnabledSystemUIMode(targetMode);
      }
    }
    final preview = _previewSize(context, isLandscape: isLandscape);

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
                Positioned.fill(child: Center(child: _preview(preview))),
                _zoomHud(context),

                // Nav buttons: physical top of phone
                if (isLandscape)
                  _landscapeStrip(
                    isLandscapeLeft: isLandscapeLeft,
                    physicalTop: true,
                    items: [
                      _navButton(child: _groupsButton()),
                      _navButton(child: _uploadButton()),
                      _navButton(child: _accountButton()),
                    ],
                  )
                else ...[
                  Positioned(
                    top: 50,
                    left: 25,
                    child: _navButton(child: _groupsButton()),
                  ),
                  Positioned(
                    top: 50,
                    left: 0,
                    right: 0,
                    child: Center(child: _navButton(child: _uploadButton())),
                  ),
                  Positioned(
                    top: 50,
                    right: 25,
                    child: _navButton(child: _accountButton()),
                  ),
                ],

                // Shutter buttons: physical bottom of phone
                if (isLandscape)
                  _landscapeStrip(
                    isLandscapeLeft: isLandscapeLeft,
                    physicalTop: false,
                    items: [_flashButton(), _shutterButton(), _flipButton()],
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
                        _flipButton(),
                      ],
                    ),
                  ),
              ],
            );
          } else if (snapshot.hasError) {
            debugPrint("Camera initialization failed: ${snapshot.error}");
            return Center(
              child: Text(context.l10n.camera_init_failed,
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
