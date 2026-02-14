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
  });

  @override
  Widget build(BuildContext context) {

    final bgColor = color.withValues(alpha: opacity);

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, color: color),
          if (icon != null)
            const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    if (blurBackground) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            color: Colors.black.withValues(alpha: 0.3),
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
