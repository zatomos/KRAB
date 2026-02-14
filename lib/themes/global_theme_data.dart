import 'package:flutter/material.dart';

class GlobalThemeData {
  static ThemeData darkThemeData = ThemeData(
    colorScheme: darkColorScheme,
    focusColor: _darkFocusColor,
  );

  static const ColorScheme darkColorScheme = ColorScheme(
    primary: Color(0xffdd6b3a),
    onPrimary: Colors.black45,
    secondary: Color(0xffcb5625),
    onSecondary: Color(0xff90d0ff),
    error: Colors.redAccent,
    onError: Colors.white,
    surface: Color(0xff181818),
    surfaceBright: Color(0xff242424),
    surfaceTint: Color(0xFF1B1B1B),
    onSurface: Color(0xffe1e1e1),
    onSurfaceVariant: Color(0xffbebebe),
    brightness: Brightness.dark,
  );

  static const _darkFocusColor = Color(0xFF1a1a1a);
}
