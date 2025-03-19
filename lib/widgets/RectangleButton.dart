import 'package:flutter/material.dart';

import 'package:krab/themes/GlobalThemeData.dart';

class RectangleButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final Color? backgroundColor;
  final Color textColor;
  final double width;
  final double height;

  const RectangleButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.backgroundColor,
    this.textColor = Colors.white,
    this.width = 200.0,
    this.height = 50.0,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveBackgroundColor = backgroundColor ?? GlobalThemeData.darkColorScheme.primary;
    return SizedBox(
      width: width,
      height: height,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: effectiveBackgroundColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}
