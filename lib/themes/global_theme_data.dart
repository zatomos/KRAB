import 'package:flutter/material.dart';

class GlobalThemeData {
  static const ColorScheme darkColorScheme = ColorScheme(
    primary: Color(0xffdd6b3a),
    onPrimary: Colors.black45,
    secondary: Color(0xffdb5f2a),
    onSecondary: Colors.white,
    error: Colors.redAccent,
    onError: Colors.white,
    surface: Color(0xff181818),
    surfaceBright: Color(0xff242424),
    surfaceTint: Color(0xff1b1b1b),
    onSurface: Color(0xffe1e1e1),
    onSurfaceVariant: Color(0xffbebebe),
    brightness: Brightness.dark,
  );

  static const Color success = Color(0xff4caf50);

  static const double dialogActionsOverflowSpacing = 8.0;
  static const double popupMenuRadius = 12.0;

  /// Tracking for text set in Rubik Medium (w500).
  static const double mediumTracking = -0.15;
}
