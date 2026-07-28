import 'dart:ui';

import 'package:flutter/material.dart';

/// The frosted look shared by every piece of chrome over a photo.
class FrostedSurface extends StatelessWidget {
  final BorderRadius borderRadius;
  final Color tint;
  final Widget child;
  final double sigma;
  final double progress;

  const FrostedSurface({
    super.key,
    required this.borderRadius,
    required this.tint,
    required this.child,
    this.sigma = 8,
    this.progress = 1,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: ClipRect(
        child: BackdropFilter.grouped(
          enabled: progress > 0,
          filter: ImageFilter.blur(
              sigmaX: sigma * progress, sigmaY: sigma * progress),
          child: Container(
            decoration: BoxDecoration(
              color: tint.withValues(alpha: tint.a * progress),
              borderRadius: borderRadius,
            ),
            child: Opacity(opacity: progress, child: child),
          ),
        ),
      ),
    );
  }
}

Color get frostedTint => Colors.black.withValues(alpha: 0.35);

/// A circular frosted icon button.
class CircleAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double progress;

  /// Invisible margin that catches near-misses.
  final double hitMargin;

  final Key? visualKey;

  const CircleAction({
    super.key,
    required this.icon,
    required this.onTap,
    required this.progress,
    this.hitMargin = 12,
    this.visualKey,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(hitMargin),
        child: ClipOval(
          key: visualKey,
          child: RepaintBoundary(
            child: InkWell(
              borderRadius: BorderRadius.circular(32),
              onTap: onTap,
              child: FrostedSurface(
                borderRadius: BorderRadius.circular(999),
                tint: frostedTint,
                progress: progress,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(icon, color: Colors.white, size: 30),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Present a frosted dialog over the photo.
Future<T?> showFrostedDialog<T>(
  BuildContext context, {
  required EdgeInsets padding,
  required Widget Function(BuildContext context) content,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, __) => Dialog(
      backgroundColor: Colors.black.withValues(alpha: 0.3),
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: frostedTint,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: content(context),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
        child: child,
      );
    },
  );
}
