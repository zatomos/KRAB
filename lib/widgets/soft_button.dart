import 'dart:ui';
import 'package:flutter/material.dart';

class SoftButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final IconData? icon;
  final double opacity;
  final double radius;
  final EdgeInsets padding;
  final bool blurBackground;
  final double? width;
  final double? height;
  final double progress;  // entrance progress
  final double minLabelWidth;

  const SoftButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = Colors.white,
    this.icon,
    this.opacity = 0.15,
    this.radius = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.blurBackground = false,
    this.progress = 1,
    this.width,
    this.height,
    this.minLabelWidth = 0,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = color.withValues(alpha: opacity * progress);
    final hasFixedSize = width != null || height != null;

    Widget content = Container(
      width: width,
      height: height,
      padding: padding,
      alignment: hasFixedSize ? Alignment.center : null,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Opacity(
        opacity: progress,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, color: color),
            if (icon != null) const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(minWidth: minLabelWidth),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  // Equal-width digits so the count doesn't jitter per value.
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (blurBackground) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        // Shares the enclosing BackdropGroup's blur pass when one is present
        // Falls back to a standalone pass otherwise.
        child: BackdropFilter.grouped(
          enabled: progress > 0,
          filter:
              ImageFilter.blur(sigmaX: 15 * progress, sigmaY: 15 * progress),
          child: Container(
            color: Colors.black.withValues(alpha: 0.3 * progress),
            child: content,
          ),
        ),
      );
    }

    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: onPressed,
      child: content,
    );
  }
}
