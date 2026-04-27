import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/services/file_saver.dart';
import 'package:krab/widgets/comments_bottom_sheet.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/user_avatar.dart';
import 'package:krab/themes/global_theme_data.dart';

Uint8List? _createBlurredBackgroundBytes(Uint8List sourceBytes) {
  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) return null;

  final resized = img.copyResize(
    decoded,
    width: 128,
    interpolation: img.Interpolation.average,
  );
  final blurred = img.gaussianBlur(resized, radius: 16);
  return Uint8List.fromList(img.encodeJpg(blurred, quality: 75));
}

class FullImagePage extends StatefulWidget {
  final krab_user.User uploader;
  final String imageId;
  final String groupId;
  final ImageData lowResImageData;
  final int commentCount;
  final Future<Uint8List?> Function() loadFullImage;
  final Future<Uint8List?>? preloadedFullImage;

  const FullImagePage({
    super.key,
    required this.uploader,
    required this.imageId,
    required this.groupId,
    required this.lowResImageData,
    required this.commentCount,
    required this.loadFullImage,
    this.preloadedFullImage,
  });

  @override
  State<FullImagePage> createState() => _FullImagePageState();
}

class _FullImagePageState extends State<FullImagePage>
    with SingleTickerProviderStateMixin {
  late Uint8List _displayedBytes;
  Uint8List? _blurredBackgroundBytes;
  bool _heroFlightActive = true;
  Timer? _heroFlightTimer;

  final TransformationController _transformationController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;

  late AnimationController _animationController;
  Animation<Matrix4>? _animation;
  double? _naturalWidth;
  double? _naturalHeight;
  bool _isClamping = false;
  bool _isZoomAnimating = false;
  bool _isUserInteracting = false;
  bool _interactionHadTransform = false;
  bool _doubleTapZoomedIn = false;
  // Keep transform-listener clamping paused after double-tap completes to
  // avoid a correction pass in the same animation cycle
  bool _suspendAutoClampUntilInteraction = false;
  Size _screenSize = const Size(1, 1);

  String get _description => widget.lowResImageData.description ?? '';

  @override
  void initState() {
    super.initState();
    _displayedBytes = widget.lowResImageData.imageBytes;
    _blurredBackgroundBytes = null;

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )
      ..addListener(() {
        if (_animation != null) {
          _transformationController.value = _animation!.value;
        }
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          _isZoomAnimating = false;
          _suspendAutoClampUntilInteraction = true;
          _syncDoubleTapStateFromScale();
        }
      });

    _transformationController.addListener(_onTransformChanged);
    _loadNaturalImageSize();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _heroFlightTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() => _heroFlightActive = false);
        }
      });
      _prepareBlurredBackground();
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (mounted) _loadFullRes();
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenSize = MediaQuery.of(context).size;
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    if (currentScale <= 1.0) {
      _applyClampNow();
    }
  }

  @override
  void dispose() {
    _heroFlightTimer?.cancel();
    _transformationController.removeListener(_onTransformChanged);
    _animationController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  void _loadNaturalImageSize() {
    MemoryImage(widget.lowResImageData.imageBytes)
        .resolve(const ImageConfiguration())
        .addListener(ImageStreamListener((ImageInfo info, bool _) {
      if (!mounted) return;
      _naturalWidth = info.image.width.toDouble();
      _naturalHeight = info.image.height.toDouble();
      setState(() {});
      final currentScale = _transformationController.value.getMaxScaleOnAxis();
      if (currentScale <= 1.0) {
        _applyClampNow();
      }
    }));
  }

  Matrix4 _matrixWithScaleAndTranslation(double scale, double tx, double ty) {
    return Matrix4.diagonal3Values(scale, scale, 1.0)
      ..setTranslationRaw(tx, ty, 0.0);
  }

  (double, double) _translationLimits(
    double viewport,
    double pad,
    double imageExtent,
    double scale,
  ) {
    // Returns the [min, max] translation range for one axis. If scaled content
    // is smaller than viewport, both values collapse to the centered position
    final scaledImageExtent = scale * imageExtent;
    if (scaledImageExtent > viewport) {
      return (
        viewport - scale * (pad + imageExtent),
        -scale * pad,
      );
    }
    final centered = (viewport - scaledImageExtent) / 2 - scale * pad;
    return (centered, centered);
  }

  Size _imageDisplaySize() {
    final nW = _naturalWidth;
    final nH = _naturalHeight;
    final sW = _screenSize.width;
    final sH = _screenSize.height;
    if (nW == null || nH == null || sW <= 1 || sH <= 1) {
      return Size(sW, sH);
    }
    final fitScale = min(sW / nW, sH / nH);
    return Size(nW * fitScale, nH * fitScale);
  }

  // onlyOverflowing=true: only clamp axes whose scaled content exceeds the
  // viewport — used for double-tap targets so content isn't snapped needlessly.
  Matrix4 _clampMatrix(Matrix4 source, {bool onlyOverflowing = false}) {
    if (_screenSize.width < 2 || _screenSize.height < 2) return source.clone();

    final sW = _screenSize.width;
    final sH = _screenSize.height;
    final imageSize = _imageDisplaySize();
    final iW = imageSize.width;
    final iH = imageSize.height;
    final padX = (sW - iW) / 2;
    final padY = (sH - iH) / 2;

    final z = source.getMaxScaleOnAxis();
    double tx = source[12];
    double ty = source[13];

    if (!onlyOverflowing || z * iW > sW) {
      final (minTx, maxTx) = _translationLimits(sW, padX, iW, z);
      tx = tx.clamp(minTx, maxTx).toDouble();
    }
    if (!onlyOverflowing || z * iH > sH) {
      final (minTy, maxTy) = _translationLimits(sH, padY, iH, z);
      ty = ty.clamp(minTy, maxTy).toDouble();
    }

    return _matrixWithScaleAndTranslation(z, tx, ty);
  }

  void _syncDoubleTapStateFromScale() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if (scale >= 2.5) {
      _doubleTapZoomedIn = true;
    } else if (scale <= 1.5) {
      _doubleTapZoomedIn = false;
    }
  }

  void _applyClampNow() {
    if (_isClamping) return;
    final clamped = _clampMatrix(_transformationController.value);
    _setTransformIfChanged(clamped, epsilon: 0.5);
  }

  void _onInteractionStart(ScaleStartDetails _) {
    _isUserInteracting = true;
    _interactionHadTransform = false;
    _suspendAutoClampUntilInteraction = false;
    if (_isZoomAnimating) {
      _animationController.stop();
      _isZoomAnimating = false;
    }
  }

  void _onInteractionEnd(ScaleEndDetails _) {
    _isUserInteracting = false;
    if (_interactionHadTransform) {
      _applyClampNow();
      _syncDoubleTapStateFromScale();
    }
  }

  void _onTransformChanged() {
    if (_isClamping || _isUserInteracting || _isZoomAnimating) return;
    // Let double-tap settle at its precomputed end matrix before automatic
    // clamping resumes on the next user interaction
    if (_suspendAutoClampUntilInteraction) return;
    _applyClampNow();
  }

  void _onInteractionUpdate(ScaleUpdateDetails _) {
    if (!_isUserInteracting || _isZoomAnimating || _isClamping) return;
    if (_screenSize.width < 2 || _screenSize.height < 2) return;
    _interactionHadTransform = true;
    _setTransformIfChanged(_clampMatrix(_transformationController.value),
        epsilon: 0.01);
  }

  void _setTransformIfChanged(Matrix4 next, {required double epsilon}) {
    final current = _transformationController.value;
    final moved = (next[12] - current[12]).abs() > epsilon ||
        (next[13] - current[13]).abs() > epsilon;
    if (!moved) return;

    _isClamping = true;
    _transformationController.value = next;
    _isClamping = false;
  }

  Future<void> _loadFullRes() async {
    final full = await (widget.preloadedFullImage ?? widget.loadFullImage());
    if (!mounted) return;

    if (full != null) {
      await precacheImage(MemoryImage(full), context);
      if (!mounted) return;
      setState(() {
        _displayedBytes = full;
      });
    }
  }

  Future<void> _prepareBlurredBackground() async {
    final blurred = await compute(
      _createBlurredBackgroundBytes,
      widget.lowResImageData.imageBytes,
    );
    if (!mounted || blurred == null) return;
    setState(() => _blurredBackgroundBytes = blurred);
  }

  Widget _frostedSurface({
    required BorderRadius borderRadius,
    required Color tint,
    required Widget child,
    double sigma = 8,
  }) {
    final decorated = Container(
      decoration: BoxDecoration(color: tint, borderRadius: borderRadius),
      child: child,
    );
    if (_heroFlightActive) {
      return ClipRRect(borderRadius: borderRadius, child: decorated);
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: decorated,
        ),
      ),
    );
  }

  void _openComments() {
    final maxSheetHeight = MediaQuery.of(context).size.height * (3 / 4);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: CommentsBottomSheet(
          uploaderId: widget.lowResImageData.uploadedBy,
          imageId: widget.imageId,
          groupId: widget.groupId,
        ),
      ),
    );
  }

  void _handleDoubleTap() {
    if (_doubleTapDetails == null) return;

    _animationController.stop();
    _isZoomAnimating = false;
    _suspendAutoClampUntilInteraction = false;
    _syncDoubleTapStateFromScale();
    final position = _doubleTapDetails!.localPosition;
    final bool zoomIn = !_doubleTapZoomedIn;
    final double newScale = zoomIn ? 3.0 : 1.0;

    final Matrix4 begin = _transformationController.value.clone();
    final Matrix4 end;
    if (!zoomIn) {
      end = _clampMatrix(_matrixWithScaleAndTranslation(1.0, 0, 0));
    } else {
      final imageSize = _imageDisplaySize();
      final sW = _screenSize.width;
      final sH = _screenSize.height;
      final padX = (sW - imageSize.width) / 2;
      final padY = (sH - imageSize.height) / 2;
      final Offset scenePoint = _transformationController.toScene(position);
      final desiredAnchorX =
          scenePoint.dx.clamp(padX, padX + imageSize.width).toDouble();
      final desiredAnchorY =
          scenePoint.dy.clamp(padY, padY + imageSize.height).toDouble();
      final targetTx = position.dx - desiredAnchorX * newScale;
      final targetTy = position.dy - desiredAnchorY * newScale;
      end = _clampMatrix(
        _matrixWithScaleAndTranslation(newScale, targetTx, targetTy),
        onlyOverflowing: true,
      );
    }
    _doubleTapZoomedIn = zoomIn;

    _isZoomAnimating = true;
    _animation = Matrix4Tween(
      begin: begin,
      end: end,
    ).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.linear,
      ),
    );

    _animationController
      ..reset()
      ..forward();
  }

  void _showFullDescriptionDialog() {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final uploadDate = DateFormat.yMMMMd(locale).add_jm().format(
          DateTime.parse(widget.lowResImageData.createdAt).toLocal(),
        );
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black.withValues(alpha: 0.3),
          insetPadding: const EdgeInsets.all(20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Metadata
                        UserAvatar(widget.uploader, radius: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.uploader.username,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                uploadDate,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Symbols.close_rounded,
                              color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Description text
                    _description.isEmpty
                        ? Text(
                            context.l10n.no_description,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 15,
                              fontStyle: FontStyle.italic,
                              height: 1.3,
                            ),
                          )
                        : Text(
                            _description,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              height: 1.3,
                            ),
                          ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: Transform.scale(
                scale: 1.2,
                child: (_heroFlightActive || _blurredBackgroundBytes == null)
                    ? ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                        child: Image.memory(
                          widget.lowResImageData.imageBytes,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.low,
                          gaplessPlayback: true,
                        ),
                      )
                    : Image.memory(
                        _blurredBackgroundBytes!,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                        gaplessPlayback: true,
                      ),
              ),
            ),
          ),

          Positioned.fill(
            child: RepaintBoundary(
              child: Container(color: Colors.black.withValues(alpha: 0.7)),
            ),
          ),

          // Main Image
          Positioned.fill(
            child: RepaintBoundary(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTapDown: (d) => _doubleTapDetails = d,
                onDoubleTap: _handleDoubleTap,
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  minScale: 1.0,
                  maxScale: 10,
                  clipBehavior: Clip.none,
                  onInteractionStart: _onInteractionStart,
                  onInteractionUpdate: _onInteractionUpdate,
                  onInteractionEnd: _onInteractionEnd,
                  child: Hero(
                    tag: "image_${widget.imageId}",
                    child: SizedBox(
                      width: _screenSize.width,
                      height: _screenSize.height,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeOut,
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: Image.memory(
                          _displayedBytes,
                          key: ValueKey<int>(_displayedBytes.hashCode),
                          fit: BoxFit.contain,
                          width: _screenSize.width,
                          height: _screenSize.height,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Top Buttons
          Positioned(
            top: 40,
            left: 16,
            child: ClipOval(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => Navigator.pop(context),
                  customBorder: const CircleBorder(),
                  child: RepaintBoundary(
                    child: _frostedSurface(
                      borderRadius: BorderRadius.circular(999),
                      tint: Colors.white.withValues(alpha: 0.15),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Symbols.close_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            top: 40,
            right: 16,
            child: ClipOval(
              child: RepaintBoundary(
                child: InkWell(
                  borderRadius: BorderRadius.circular(32),
                  onTap: () async {
                    final success = await downloadImage(
                      _displayedBytes,
                      widget.lowResImageData.uploadedBy,
                      widget.lowResImageData.createdAt,
                    );
                    showSnackBar(
                      success ? "Image saved!" : "Failed to save image",
                      color: success ? Colors.green : Colors.red,
                    );
                  },
                  child: _frostedSurface(
                    borderRadius: BorderRadius.circular(999),
                    tint: Colors.white.withValues(alpha: 0.15),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child:
                          Icon(Symbols.download_rounded, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Image description
          Positioned(
            bottom: 15,
            left: 10,
            right: 90,
            // Pill
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _showFullDescriptionDialog,
              // Background
              child: SizedBox(
                height: 44,
                child: RepaintBoundary(
                  child: _frostedSurface(
                    borderRadius: BorderRadius.circular(14),
                    tint: Colors.black.withValues(alpha: 0.35),
                    sigma: 10,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          UserAvatar(widget.uploader, radius: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _description.isEmpty
                                ? Text(
                                    context.l10n.no_description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.5),
                                      fontSize: 14,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  )
                                : Text(
                                    _description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Comments button
          Positioned(
            bottom: 15,
            right: 10,
            child: SoftButton(
              onPressed: _openComments,
              label: widget.commentCount.toString(),
              icon: Symbols.comment_rounded,
              color: GlobalThemeData.darkColorScheme.primary,
              opacity: 0.3,
              blurBackground: !_heroFlightActive,
            ),
          ),
        ],
      ),
    );
  }
}
