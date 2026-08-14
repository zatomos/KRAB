import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/pages/viewer/frosted.dart';

const double _doubleTapScale = 2.5;

Future<void> showImagePreview(BuildContext context, File file) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.9),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, __) => _ImagePreview(file: file),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: child,
    ),
  );
}

class _ImagePreview extends StatefulWidget {
  final File file;

  const _ImagePreview({required this.file});

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _doubleTapController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<double>? _doubleTapAnimation;
  VoidCallback? _doubleTapListener;

  @override
  void dispose() {
    if (_doubleTapListener != null) {
      _doubleTapAnimation?.removeListener(_doubleTapListener!);
    }
    _doubleTapController.dispose();
    super.dispose();
  }

  GestureConfig _initGestureConfig(ExtendedImageState state) => GestureConfig(
        initialScale: 1.0,
        minScale: 1.0,
        animationMinScale: 1.0,
        maxScale: 5.0,
        animationMaxScale: 6.0,
        cacheGesture: false,
      );

  void _onDoubleTap(ExtendedImageGestureState state) {
    final pointer = state.pointerDownPosition;
    final begin = state.gestureDetails?.totalScale ?? 1.0;
    final end = begin <= 1.01 ? _doubleTapScale : 1.0;

    if (_doubleTapListener != null) {
      _doubleTapAnimation?.removeListener(_doubleTapListener!);
    }
    _doubleTapController.stop();
    _doubleTapController.value = 0.0;
    _doubleTapAnimation = Tween<double>(begin: begin, end: end).animate(
      CurvedAnimation(parent: _doubleTapController, curve: Curves.easeOutCubic),
    );
    _doubleTapListener = () => state.handleDoubleTap(
          scale: _doubleTapAnimation!.value,
          doubleTapPosition: pointer,
        );
    _doubleTapAnimation!.addListener(_doubleTapListener!);
    _doubleTapController.forward();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExtendedImage.file(
            widget.file,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            mode: ExtendedImageMode.gesture,
            onDoubleTap: _onDoubleTap,
            initGestureConfigHandler: _initGestureConfig,
          ),
          // Close btn
          Positioned(
            top: MediaQuery.paddingOf(context).top + 4,
            left: 4,
            child: CircleAction(
              icon: Symbols.close_rounded,
              onTap: () => Navigator.pop(context),
              progress: 1,
            ),
          ),
        ],
      ),
    );
  }
}
