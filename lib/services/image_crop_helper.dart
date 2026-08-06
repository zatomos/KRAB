import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';

import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/user_preferences.dart';

/// Picks an image from the gallery and crops it to a 1:1 square.
///
/// Used for profile pictures and group icons. Returns the cropped File, or
/// `null` if the user cancelled either the picker or the cropper.
Future<File?> pickAndCropSquareImage({required String toolbarTitle}) async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null) return null;

  final scheme = GlobalThemeData.schemeFor(UserPreferences.themeMode.value);

  try {
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      maxHeight: 512,
      maxWidth: 512,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: toolbarTitle,
          toolbarColor: scheme.surface,
          toolbarWidgetColor: scheme.onSurface,
          activeControlsWidgetColor: scheme.primary,
          statusBarLight: scheme.brightness == Brightness.light,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
        ),
      ],
    );

    if (cropped == null) return null;
    return File(cropped.path);
  } finally {
    try {
      final original = File(picked.path);
      if (await original.exists()) await original.delete();
    } catch (e) {
      debugPrint('Could not delete the picked original: $e');
    }
  }
}
