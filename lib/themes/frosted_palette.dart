import 'package:flutter/material.dart';

import 'package:krab/themes/global_theme_data.dart';

/// The glass palette for chrome laid over a photo.

const Color frostedOn = Colors.white;
const Color frostedOnMuted = Color(0x99ffffff);
final Color frostedAccent = GlobalThemeData.darkColorScheme.primary;
final Color frostedError = GlobalThemeData.darkColorScheme.error;

extension FrostedPalette on BuildContext {
  bool get _lightGlass => Theme.of(this).brightness == Brightness.light;

  Color get frostedTint =>
      Colors.black.withValues(alpha: _lightGlass ? 0.22 : 0.35);

  Color get frostedTintStrong =>
      Colors.black.withValues(alpha: _lightGlass ? 0.45 : 0.60);

  Color get frostedVeil =>
      Colors.black.withValues(alpha: _lightGlass ? 0.3 : 0.7);

  Color get frostedBorder =>
      Colors.white.withValues(alpha: _lightGlass ? 0.20 : 0.15);
}
