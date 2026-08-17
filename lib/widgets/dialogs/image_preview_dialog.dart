import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/pages/viewer/frosted.dart';
import 'package:krab/widgets/zoomable_image.dart';

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

class _ImagePreview extends StatelessWidget {
  final File file;

  const _ImagePreview({required this.file});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ZoomableImage(image: FileImage(file)),
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
