import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

extension MutedColor on ColorScheme {
  Color get muted => onSurfaceVariant.withValues(alpha: 0.75);
}

SystemUiOverlayStyle systemBarsFor(Brightness background) {
  final isDark = background == Brightness.dark;
  return SystemUiOverlayStyle(
    systemNavigationBarColor: isDark ? Colors.black : Colors.white,
    systemNavigationBarIconBrightness:
        isDark ? Brightness.light : Brightness.dark,
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
  );
}

class GlobalThemeData {
  static const ColorScheme darkColorScheme = ColorScheme(
    primary: Color(0xffdd6b3a),
    onPrimary: Colors.black45,
    primaryContainer: Color(0xffdd6b3a),
    onPrimaryContainer: onAccent,
    secondary: Color(0xffdb5f2a),
    onSecondary: Colors.white,
    tertiary: Color(0xffe3a008),
    onTertiary: Colors.black45,
    error: Colors.redAccent,
    onError: Colors.white,
    errorContainer: Color(0xff5c1a17),
    onErrorContainer: Color(0xffffdad6),
    surface: Color(0xff181818),
    onSurface: Color(0xffe1e1e1),
    onSurfaceVariant: Color(0xffbebebe),
    surfaceContainer: Color(0xff242424),
    surfaceContainerHighest: Color(0xff2f2f2f),
    outlineVariant: Color(0xff3a3a3a),
    surfaceTint: Colors.transparent,
    brightness: Brightness.dark,
  );

  static const ColorScheme lightColorScheme = ColorScheme(
    primary: Color(0xffc0541f),
    onPrimary: Colors.white,
    primaryContainer: Color(0xffc0541f),
    onPrimaryContainer: onAccent,
    secondary: Color(0xffb84e1c),
    onSecondary: Colors.white,
    tertiary: Color(0xffb26a00),
    onTertiary: Colors.white,
    error: Color(0xffc62828),
    onError: Colors.white,
    errorContainer: Color(0xfff9dedc),
    onErrorContainer: Color(0xff8c1d18),
    surface: Colors.white,
    onSurface: Color(0xff1b1b1b),
    onSurfaceVariant: Color(0xff5a5754),
    surfaceContainer: Color(0xfffff5eb),
    surfaceContainerHighest: Color(0xfff7ece0),
    outlineVariant: Color(0xffe6ddd4),
    surfaceTint: Colors.transparent,
    brightness: Brightness.light,
  );

  static const Color success = Color(0xff4caf50);

  static const Color onAccent = Colors.black45;

  static const double dialogActionsOverflowSpacing = 8.0;
  static const double popupMenuRadius = 12.0;

  /// Tracking for text set in Rubik Medium (w500).
  static const double mediumTracking = -0.15;

  static ThemeData _themeFrom(ColorScheme scheme) => ThemeData(
        actionIconTheme: ActionIconThemeData(
          backButtonIconBuilder: (context) {
            return const Icon(
              Icons.arrow_back_ios_new_rounded,
              fill: 1,
              size: 24,
            );
          },
        ),
        colorScheme: scheme,
        useMaterial3: true,
        fontFamily: 'Rubik',
        iconTheme: const IconThemeData(weight: 650),
        popupMenuTheme: PopupMenuThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(popupMenuRadius),
          ),
        ),
      );

  static final ThemeData dark = _themeFrom(darkColorScheme);
  static final ThemeData light = _themeFrom(lightColorScheme);

  static ColorScheme schemeFor(ThemeMode mode) => switch (mode) {
        ThemeMode.light => lightColorScheme,
        ThemeMode.dark => darkColorScheme,
        ThemeMode.system =>
          PlatformDispatcher.instance.platformBrightness == Brightness.light
              ? lightColorScheme
              : darkColorScheme,
      };
}
