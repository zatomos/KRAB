import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';

import 'package:krab/themes/global_theme_data.dart';

/// Picks an image from the gallery and crops it to a 1:1 square.
///
/// Used for profile pictures and group icons. Returns the cropped File, or
/// `null` if the user cancelled either the picker or the cropper.
Future<File?> pickAndCropSquareImage() async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null) return null;

  final cropped = await ImageCropper().cropImage(
    sourcePath: picked.path,
    aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
    maxHeight: 1000,
    maxWidth: 1000,
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: 'Crop Image',
        toolbarColor: GlobalThemeData.darkColorScheme.surface,
        toolbarWidgetColor: Colors.white,
        activeControlsWidgetColor: GlobalThemeData.darkColorScheme.primary,
        statusBarLight: false,
        initAspectRatio: CropAspectRatioPreset.square,
        lockAspectRatio: true,
      ),
    ],
  );

  if (cropped == null) return null;
  return File(cropped.path);
}
