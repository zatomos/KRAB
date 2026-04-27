import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:native_device_orientation/native_device_orientation.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/widgets/image_sent_dialog.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/user_avatar.dart';
import 'package:krab/user_preferences.dart';
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
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  Timer? _zoomTimer;
  bool _zoomApplying = false;
  final Duration _zoomPeriod = const Duration(milliseconds: 16); // ~60fps

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
    _zoomTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /// Dispose camera resources
  Future<void> _disposeCamera() async {
    _zoomTimer?.cancel();
    _zoomTimer = null;
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
      MaterialPageRoute(builder: (_) => page),
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
    _currentZoom = 1.0;

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
      final double toApply = _currentZoom;
      try {
        await ctrl.setZoomLevel(toApply);
      } catch (e) {
        debugPrint("setZoomLevel failed: $e");
      } finally {
        _zoomApplying = false;
        if ((toApply - _currentZoom).abs() > 1e-3) _scheduleZoomApply();
      }
    });
  }

  Future<void> _onZoomChanged(double zoom) async {
    if (mounted) setState(() => _currentZoom = zoom.clamp(_minZoom, _maxZoom).toDouble());
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

  Future<void> _showSendImageDialog(File imageFile) async {
    final TextEditingController description = TextEditingController();
    final favoriteGroups = await UserPreferences.getFavoriteGroups();
    Set<String> selectedGroups = {};
    selectedGroups.addAll(favoriteGroups);
    final groupsFuture = getUserGroups();
    if (!mounted) return;

    // Capture the CameraPage context before entering any dialog builder so
    // nested showDialog calls always use a live context
    final outerContext = context;

    setState(() => _dialogOpen = true);
    try {
      await showDialog(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              final isLandscape =
                  MediaQuery.of(context).orientation == Orientation.landscape;
              final screenWidth = MediaQuery.of(context).size.width;
              final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
              final keyboardOpen = keyboardHeight > 0;

              final insetV = isLandscape ? 4.0 : 24.0;
              // Zero spacer in landscape with keyboard to reclaim every pixel
              final spacerH = (isLandscape && keyboardOpen) ? 0.0 : 8.0;

              final groupsWidget = FutureBuilder(
                future: groupsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
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
                      return Center(child: Text(context.l10n.join_group_first));
                    }
                    return ListView.builder(
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
                    );
                  }
                },
              );

              final Widget dialogContent;
              if (isLandscape) {
                dialogContent = Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(imageFile, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          Flexible(child: groupsWidget),
                        ],
                      ),
                    ),
                  ],
                );
              } else {
                dialogContent = Column(
                  children: [
                    if (!keyboardOpen) ...[
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
                    ],
                    Flexible(child: groupsWidget),
                  ],
                );
              }

              return AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                insetPadding: EdgeInsets.symmetric(
                  horizontal: isLandscape ? 16 : 40,
                  vertical: insetV,
                ),
                title: isLandscape ? null : Text(context.l10n.select_groups),
                contentPadding: (isLandscape && keyboardOpen)
                    ? EdgeInsets.zero
                    : isLandscape
                        ? const EdgeInsets.fromLTRB(16, 16, 16, 0)
                        : null,
                actionsPadding: isLandscape
                    ? const EdgeInsets.fromLTRB(16, 4, 16, 8)
                    : null,
                content: SizedBox(
                  width: screenWidth,
                  child: LayoutBuilder(
                    builder: (_, cst) {
                      // Reserve room for description + spacer +  safety margin.
                      final gh = cst.maxHeight.isFinite
                          ? (cst.maxHeight - spacerH - 88).clamp(0.0, 400.0)
                          : (MediaQuery.of(context).size.height * 0.40)
                              .clamp(60.0, 400.0);
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Visibility(
                            visible: !(isLandscape && keyboardOpen),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxHeight: gh),
                              child: dialogContent,
                            ),
                          ),
                          SizedBox(height: spacerH),
                          RoundedInputField(
                            hintText: context.l10n.add_description,
                            capitalizeSentences: true,
                            controller: description,
                          ),
                        ],
                      );
                    },
                  ),
                ),
                actions: keyboardOpen
                    ? null
                    : [
                        SoftButton(
                            onPressed: () => Navigator.of(context).pop(),
                            label: context.l10n.cancel),
                        SoftButton(
                            onPressed: () async {
                              if (selectedGroups.isEmpty) {
                                await showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text(context.l10n.error),
                                    content: Text(
                                        context.l10n.select_at_least_one_group),
                                    actions: [
                                      SoftButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          label: "OK",
                                          color: GlobalThemeData
                                              .darkColorScheme.primary),
                                    ],
                                  ),
                                );
                                return;
                              }

                              showDialog(
                                context: context,
                                barrierDismissible: false,
                                builder: (context) => const Center(
                                    child: CircularProgressIndicator()),
                              );

                              final response = await sendImageToGroups(
                                imageFile,
                                selectedGroups.toList(),
                                description.text,
                              );
                              if (!context.mounted) return;

                              Navigator.of(context).pop(); // loading
                              Navigator.of(context).pop(); // main dialog

                              if (!outerContext.mounted) return;
                              await showDialog(
                                context: outerContext,
                                builder: (context) => ImageSentDialog(
                                  success: response.success,
                                  errorMsg: response.error,
                                ),
                              );
                            },
                            label: context.l10n.send,
                            color: GlobalThemeData.darkColorScheme.primary),
                      ],
              );
            },
          );
        },
      );
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
    final nativeOrientation = NativeDeviceOrientationReader.orientation(context);
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
    final maxPreviewHeight =
        MediaQuery.of(context).size.height * (isLandscape ? 0.9 : 0.7);
    final maxPreviewWidth =
        MediaQuery.of(context).size.width * (isLandscape ? 0.85 : 0.9);
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
                        '${_currentZoom.toStringAsFixed(1)}x',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ),

                // Nav buttons: physical top of phone
                if (isLandscape)
                  Positioned(
                    left: nativeOrientation == NativeDeviceOrientation.landscapeLeft ? 10 : null,
                    right: nativeOrientation == NativeDeviceOrientation.landscapeLeft ? null : 10,
                    top: 40,
                    bottom: 40,
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
                    left: nativeOrientation == NativeDeviceOrientation.landscapeLeft ? null : 10,
                    right: nativeOrientation == NativeDeviceOrientation.landscapeLeft ? 10 : null,
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

