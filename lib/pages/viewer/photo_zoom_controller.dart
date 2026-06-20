import 'dart:math';
import 'package:flutter/material.dart';

/// Owns the pinch/pan/double-tap zoom system for a full-screen photo.
class PhotoZoomController {
  PhotoZoomController({
    required TickerProvider vsync,
    this.onZoomChanged,
    this.onNaturalSizeResolved,
  }) {
    _animationController = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 260),
    )
      ..addListener(() {
        if (_animation != null) {
          transformationController.value = _animation!.value;
        }
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          isZoomAnimating = false;
          suspendAutoClampUntilInteraction = true;
          syncDoubleTapStateFromScale();
        }
      });
    transformationController.addListener(_onTransformChanged);
  }

  /// Notified with whether the image is currently zoomed in
  final ValueChanged<bool>? onZoomChanged;

  /// Called once the source image's natural size becomes known, so the host
  /// can rebuild for layout
  final VoidCallback? onNaturalSizeResolved;

  final TransformationController transformationController =
      TransformationController();
  late final AnimationController _animationController;
  Animation<Matrix4>? _animation;

  double? _naturalWidth;
  double? _naturalHeight;
  Size screenSize = const Size(1, 1);

  bool isClamping = false;
  bool isZoomAnimating = false;
  bool isUserInteracting = false;
  bool interactionHadTransform = false;
  bool doubleTapZoomedIn = false;
  // Keep transform-listener clamping paused after double-tap completes to
  // avoid a correction pass in the same animation cycle
  bool suspendAutoClampUntilInteraction = false;

  TapDownDetails? doubleTapDetails;

  double get scale => transformationController.value.getMaxScaleOnAxis();

  void dispose() {
    transformationController.removeListener(_onTransformChanged);
    _animationController.dispose();
    transformationController.dispose();
  }

  void loadNaturalSize(MemoryImage image) {
    image.resolve(const ImageConfiguration()).addListener(
      ImageStreamListener((ImageInfo info, bool _) {
        _naturalWidth = info.image.width.toDouble();
        _naturalHeight = info.image.height.toDouble();
        onNaturalSizeResolved?.call();
        if (scale <= 1.0) applyClampNow();
      }),
    );
  }

  // ---- Geometry ------------------------------------------------------------

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
    // is smaller than viewport, both values collapse to the centered position.
    final scaledImageExtent = scale * imageExtent;
    if (scaledImageExtent > viewport) {
      return (viewport - scale * (pad + imageExtent), -scale * pad);
    }
    final centered = (viewport - scaledImageExtent) / 2 - scale * pad;
    return (centered, centered);
  }

  Size _imageDisplaySize() {
    final nW = _naturalWidth;
    final nH = _naturalHeight;
    final sW = screenSize.width;
    final sH = screenSize.height;
    if (nW == null || nH == null || sW <= 1 || sH <= 1) {
      return Size(sW, sH);
    }
    final fitScale = min(sW / nW, sH / nH);
    return Size(nW * fitScale, nH * fitScale);
  }

  // onlyOverflowing=true: only clamp axes whose scaled content exceeds the
  // viewport. Used for double-tap targets so content isn't snapped needlessly.
  Matrix4 _clampMatrix(Matrix4 source, {bool onlyOverflowing = false}) {
    if (screenSize.width < 2 || screenSize.height < 2) return source.clone();

    final sW = screenSize.width;
    final sH = screenSize.height;
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

  // ---- Clamp / state -------------------------------------------------------

  void syncDoubleTapStateFromScale() {
    if (scale >= 2.5) {
      doubleTapZoomedIn = true;
    } else if (scale <= 1.5) {
      doubleTapZoomedIn = false;
    }
  }

  void applyClampNow() {
    if (isClamping) return;
    _setTransformIfChanged(_clampMatrix(transformationController.value),
        epsilon: 0.5);
  }

  void _setTransformIfChanged(Matrix4 next, {required double epsilon}) {
    final current = transformationController.value;
    final moved = (next[12] - current[12]).abs() > epsilon ||
        (next[13] - current[13]).abs() > epsilon;
    if (!moved) return;

    isClamping = true;
    transformationController.value = next;
    isClamping = false;
  }

  void _onTransformChanged() {
    final isZoomed = scale > 1.05;
    onZoomChanged?.call(isZoomed);
    if (isClamping || isUserInteracting || isZoomAnimating) return;
    // Let double-tap settle at its precomputed end matrix before automatic
    // clamping resumes on the next user interaction.
    if (suspendAutoClampUntilInteraction) return;
    applyClampNow();
  }

  // ---- Interaction hooks (called by the host's gesture callbacks) ----------

  void onInteractionStart() {
    isUserInteracting = true;
    interactionHadTransform = false;
    suspendAutoClampUntilInteraction = false;
    if (isZoomAnimating) {
      _animationController.stop();
      isZoomAnimating = false;
    }
  }

  /// Clamp the live transform during a drag/pinch. Returns false when
  /// the controller is mid-animation/clamp or the viewport isn't measured yet.
  bool applyClampDuringInteraction() {
    if (!isUserInteracting || isZoomAnimating || isClamping) return false;
    if (screenSize.width < 2 || screenSize.height < 2) return false;
    interactionHadTransform = true;
    _setTransformIfChanged(_clampMatrix(transformationController.value),
        epsilon: 0.01);
    return true;
  }

  void onInteractionEnd() {
    isUserInteracting = false;
    if (interactionHadTransform) {
      applyClampNow();
      syncDoubleTapStateFromScale();
    }
  }

  void handleDoubleTap() {
    if (doubleTapDetails == null) return;

    _animationController.stop();
    isZoomAnimating = false;
    suspendAutoClampUntilInteraction = false;
    syncDoubleTapStateFromScale();
    final position = doubleTapDetails!.localPosition;
    final bool zoomIn = !doubleTapZoomedIn;
    final double newScale = zoomIn ? 3.0 : 1.0;

    final Matrix4 begin = transformationController.value.clone();
    final Matrix4 end;
    if (!zoomIn) {
      end = _clampMatrix(_matrixWithScaleAndTranslation(1.0, 0, 0));
    } else {
      final imageSize = _imageDisplaySize();
      final sW = screenSize.width;
      final sH = screenSize.height;
      final padX = (sW - imageSize.width) / 2;
      final padY = (sH - imageSize.height) / 2;
      final Offset scenePoint = transformationController.toScene(position);
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
    doubleTapZoomedIn = zoomIn;

    isZoomAnimating = true;
    _animation = Matrix4Tween(begin: begin, end: end).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.linear),
    );
    _animationController
      ..reset()
      ..forward();
  }
}
