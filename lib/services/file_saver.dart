import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:image/image.dart' as img;

String _safeFileName(String uploadedBy, String createdAt) {
  final raw = "krab_$uploadedBy-$createdAt";
  return raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

/// Saves imageBytes to the device gallery. Returns whether it actually landed.
Future<bool> downloadImage(
    Uint8List imageBytes, String uploadedBy, String createdAt) async {
  try {
    if (!await checkAndRequestPermissions(skipIfExists: true)) {
      debugPrint("Cannot save image: permission denied");
      return false;
    }

    // Fix image rotation before saving
    final fixedImageBytes = _fixImageRotation(imageBytes);

    final result = await SaverGallery.saveImage(
      fixedImageBytes,
      quality: 100,
      fileName: _safeFileName(uploadedBy, createdAt),
      albumPath: "Pictures/krab",
      skipIfExists: true,
    );

    if (!result.isSuccess) {
      debugPrint("Image not saved: ${result.errorMessage}");
      return false;
    }

    debugPrint("Image saved successfully");
    return true;
  } catch (e) {
    debugPrint("Error saving image: $e");
    return false;
  }
}

Future<bool> checkAndRequestPermissions({required bool skipIfExists}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return false; // Only Android and iOS platforms are supported
  }

  if (Platform.isAndroid) {
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = deviceInfo.version.sdkInt;

    if (skipIfExists) {
      // Read permission is required to check if the file already exists
      return sdkInt >= 33
          ? await Permission.photos.request().isGranted
          : await Permission.storage.request().isGranted;
    } else {
      // No read permission required for Android SDK 29 and above
      return sdkInt >= 29 ? true : await Permission.storage.request().isGranted;
    }
  } else if (Platform.isIOS) {
    // iOS permission for saving images to the gallery
    return skipIfExists
        ? await Permission.photos.request().isGranted
        : await Permission.photosAddOnly.request().isGranted;
  }

  return false; // Unsupported platforms
}

/// Fixes image rotation using `image` package
Uint8List _fixImageRotation(Uint8List imageBytes) {
  try {
    img.Image image = img.decodeImage(imageBytes)!;

    // Check orientation metadata and rotate accordingly
    img.Image fixedImage = img.bakeOrientation(image);

    return Uint8List.fromList(img.encodeJpg(fixedImage));
  } catch (e) {
    debugPrint("⚠Error fixing image rotation: $e");
    return imageBytes; // Return original if rotation fix fails
  }
}
