import 'package:flutter/material.dart';

/// How much weight a RectangleButton carries.
enum RectangleButtonStyle {
  filled,
  outlined,
}

class RectangleButton extends StatelessWidget {
  final String label;
  final IconData? icon;

  /// Null disables the button, greying it out
  final VoidCallback? onPressed;

  /// Work in progress: the icon becomes a spinner and the button stops
  /// responding
  final bool loading;

  final RectangleButtonStyle style;
  final Color? backgroundColor;
  final Color textColor;
  final double? width;
  final double height;

  const RectangleButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.loading = false,
    this.style = RectangleButtonStyle.filled,
    this.backgroundColor,
    this.textColor = Colors.white,
    this.width,
    this.height = 50.0,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null && !loading;
    final outlined = style == RectangleButtonStyle.outlined;
    final baseForeground =
        outlined ? (backgroundColor ?? colors.onSurface) : textColor;
    final foreground =
        enabled ? baseForeground : baseForeground.withValues(alpha: 0.45);

    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
    final minimumSize = Size(width ?? 160, height);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading) ...[
          SizedBox(
            width: 18,
            height: 18,
            child:
                CircularProgressIndicator(strokeWidth: 2, color: foreground),
          ),
          const SizedBox(width: 8),
        ] else if (icon != null) ...[
          Icon(icon, color: foreground),
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: TextStyle(
            color: foreground,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );

    final Widget button;
    if (outlined) {
      button = OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          minimumSize: minimumSize,
          shape: shape,
          side: BorderSide(
            color: baseForeground.withValues(alpha: enabled ? 0.5 : 0.2),
            width: 1.5,
          ),
        ),
        child: content,
      );
    } else {
      final background = backgroundColor ?? colors.primary;
      button = ElevatedButton(
        onPressed: enabled ? onPressed : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          disabledBackgroundColor: background.withValues(alpha: 0.35),
          minimumSize: minimumSize,
          shape: shape,
        ),
        child: content,
      );
    }

    if (width != null) {
      return SizedBox(width: width, height: height, child: button);
    }
    return SizedBox(height: height, child: button);
  }
}
