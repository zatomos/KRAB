import 'package:flutter/material.dart';

class GlobalThemeData {
  static const ColorScheme darkColorScheme = ColorScheme(
    primary: Color(0xffdd6b3a),
    onPrimary: Colors.black45,
    secondary: Color(0xffcb5625),
    // White rather than the black onPrimary uses: secondary is the darker of the
    // two oranges, so the contrast runs the other way (4.3:1 against 3.4:1 for
    // the off-white onSurface). It also matches the light text the neutral
    // snackbar already draws on this colour.
    onSecondary: Colors.white,
    error: Colors.redAccent,
    onError: Colors.white,
    surface: Color(0xff181818),
    surfaceBright: Color(0xff242424),
    surfaceTint: Color(0xFF1B1B1B),
    onSurface: Color(0xffe1e1e1),
    onSurfaceVariant: Color(0xffbebebe),
    brightness: Brightness.dark,
  );

  static const Color success = Color(0xff4caf50);

  static const double dialogActionsOverflowSpacing = 8.0;
  static const double popupMenuRadius = 12.0;
}
