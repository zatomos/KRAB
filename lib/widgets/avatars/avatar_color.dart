import 'package:flutter/material.dart';

/// Deterministic background color derived from a name.
///
/// Shared by the group/user avatars and anywhere a stable per-name color is
/// needed so the same group always maps to the same color.
Color colorFromName(String text, BuildContext context) {
  if (text.isEmpty) {
    return Theme.of(context).colorScheme.primaryContainer;
  }
  final hash = text.codeUnits.fold<int>(0, (acc, c) => acc + c);
  final hue = (hash % 360).toDouble();
  final hsv = HSVColor.fromAHSV(1, hue, 0.5, 0.85);
  return hsv.toColor();
}
