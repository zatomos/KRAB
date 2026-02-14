import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';

import 'package:krab/UserPreferences.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/services/debug_notifier.dart';
import 'file_saver.dart';

/// Result of image resize operation
class _ResizeResult {
  final Uint8List? bytes;
  final String? error;
  final bool decodeFailed;

  _ResizeResult({this.bytes, this.error, this.decodeFailed = false});
}

_ResizeResult _resizeWorker(Map args) {
  try {
    final Uint8List bytes = args['bytes'];
    final int maxBytes = args['maxBytes'];

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return _ResizeResult(
        bytes: bytes,
        error: 'Image decode failed',
        decodeFailed: true,
      );
    }

    final w = decoded.width;
    final h = decoded.height;
    final currentSize = w * h * 4;

    final safeMax = (maxBytes * 0.90).floor();

    if (currentSize <= safeMax) {
      return _ResizeResult(bytes: bytes);
    }

    final scale = sqrt(safeMax / currentSize);
    int newW = max(1, (w * scale).floor());

    img.Image resized = img.copyResize(
      decoded,
      width: newW,
      interpolation: img.Interpolation.linear,
    );

    // Safety pass: ensure we are under the limit
    int newSize = resized.width * resized.height * 4;
    if (newSize > maxBytes) {
      final factor = sqrt((maxBytes * 0.5) / newSize);
      newW = max(1, (resized.width * factor).floor());
      resized = img.copyResize(resized, width: newW);
    }

    return _ResizeResult(
      bytes: Uint8List.fromList(img.encodeJpg(resized, quality: 85)),
    );
  } catch (e) {
    return _ResizeResult(error: 'Resize error: $e');
  }
}

Future<_ResizeResult> _downscaleWidgetImage(Uint8List bytes, int maxBytes) async {
  try {
    return await compute(_resizeWorker, {
      'bytes': bytes,
      'maxBytes': maxBytes,
    });
  } catch (e) {
    // Fallback to synchronous resize
    debugPrint("Widget: compute() not available. Using synchronous resize.");
    try {
      return _resizeWorker({'bytes': bytes, 'maxBytes': maxBytes});
    } catch (syncError) {
      return _ResizeResult(error: 'Sync resize failed: $syncError');
    }
  }
}

Future<void> updateHomeWidget() async {
  try {
    debugPrint("Starting widget update process");
    await DebugNotifier.instance.notifyWidgetUpdateStarted();

    // Step 2: Fetch latest image ID
    final latest = await getLatestImage();
    final imageId = latest.data;
    if (imageId == null) {
      debugPrint("No latest image found. Aborting.");
      await DebugNotifier.instance
          .notifyWidgetUpdateFailed("No latest image found");
      return;
    }
    debugPrint("Latest image ID: $imageId");
    await DebugNotifier.instance.notifyWidgetStep(2, 7, "Got image ID");

    // Step 3: Download image bytes
    final imgResult = await getImage(imageId);
    final Uint8List? imageBytes = imgResult.data;

    if (imageBytes == null) {
      debugPrint("Image bytes null → abort.");
      await DebugNotifier.instance
          .notifyWidgetUpdateFailed("Image download failed: bytes null");
      return;
    }
    debugPrint("Downloaded image bytes: ${imageBytes.length}");
    await DebugNotifier.instance.notifyWidgetStep(
        3, 7, "Downloaded ${(imageBytes.length / 1024).round()}KB");

    // Step 4: Fetch image details
    final details = await getImageDetails(imageId);
    final description = details.data?['description'] ?? "";
    final uploaderId = details.data?['uploaded_by'];
    final uploaderInfo = await getUserDetails(uploaderId);

    final uploaderName = uploaderInfo.data?.username ?? "Unknown";

    debugPrint("Uploader: $uploaderName");
    debugPrint("Description: $description");
    await DebugNotifier.instance.notifyWidgetStep(4, 7, "Got details");

    // Get widget bitmap limit
    int maxBytes = await UserPreferences.getWidgetBitmapLimit();
    if (maxBytes <= 0) {
      maxBytes = 10 * 1024 * 1024;
      debugPrint("Using fallback widget bitmap limit: 10 MB");
    } else {
      debugPrint("Widget bitmap limit: $maxBytes bytes");
    }

    // Step 5: Downscale image to fit within android bitmap limits
    final resizeResult = await _downscaleWidgetImage(imageBytes, maxBytes);

    // Check for resize errors
    if (resizeResult.error != null) {
      debugPrint("Image resize failed: ${resizeResult.error}");
      await DebugNotifier.instance
          .notifyWidgetUpdateFailed("Image resize failed: ${resizeResult.error}");
      return;
    }

    if (resizeResult.bytes == null) {
      debugPrint("Image resize returned null bytes");
      await DebugNotifier.instance
          .notifyWidgetUpdateFailed("Image resize returned null");
      return;
    }

    // Warn if decode failed but we're using original bytes
    if (resizeResult.decodeFailed) {
      debugPrint("Warning: Image decode failed, using original bytes");
      await DebugNotifier.instance
          .notifyWidgetUpdateFailed("Image decode failed (using original)");
    }

    final resizedBytes = resizeResult.bytes!;
    debugPrint("Resized bytes: ${resizedBytes.length}");
    await DebugNotifier.instance.notifyWidgetStep(
        5, 7, "Resized to ${(resizedBytes.length / 1024).round()}KB");

    // Step 6: Save file to persistent app storage (not temp, which OS can clear)
    final dir = await getApplicationSupportDirectory();
    final path = "${dir.path}/krab_widget_current.jpg";
    final file = File(path);

    await file.writeAsBytes(resizedBytes, flush: true);

    debugPrint("Saved resized image → ${file.path} (${await file.length()} bytes)");
    await DebugNotifier.instance.notifyWidgetStep(6, 7, "Saved to storage");

    // Save metadata to widget
    await HomeWidget.saveWidgetData('recentImageUrl', path);
    await HomeWidget.saveWidgetData('recentImageDescription', description);
    await HomeWidget.saveWidgetData('recentImageSender', uploaderName);

    // Step 7: Update widget
    final updated = await HomeWidget.updateWidget(name: "HomeScreenWidget") ?? false;
    debugPrint("Widget update success: $updated");

    if (!updated) {
      await DebugNotifier.instance
          .notifyWidgetUpdateFailed("HomeWidget.updateWidget returned false");
      return;
    }

    // Auto-save original image if enabled
    if (await UserPreferences.getAutoImageSave()) {
      await downloadImage(
        imageBytes,
        uploaderName,
        DateTime.now().toIso8601String(),
      );
    }

    debugPrint("Widget update process complete.");
    await DebugNotifier.instance.notifyWidgetUpdateSuccess(imageId);
  } catch (e, st) {
    debugPrint("Widget update failed: $e");
    debugPrint(st.toString());
    await DebugNotifier.instance.notifyWidgetUpdateFailed("Error: $e");
  }
}