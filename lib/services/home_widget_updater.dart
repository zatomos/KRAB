import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';

import 'package:krab/UserPreferences.dart';
import 'package:krab/services/supabase.dart';
import 'file_saver.dart';

Uint8List _resizeWorker(Map args) {
  final Uint8List bytes = args['bytes'];
  final int maxBytes = args['maxBytes'];

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  final w = decoded.width;
  final h = decoded.height;
  final currentSize = w * h * 4;
  
  final safeMax = (maxBytes * 0.90).floor();

  if (currentSize <= safeMax) {
    return bytes;
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

  return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
}

Future<Uint8List> _downscaleWidgetImage(Uint8List bytes, int maxBytes) async {
  try {
    return await compute(_resizeWorker, {
      'bytes': bytes,
      'maxBytes': maxBytes,
    });
  } catch (e) {
    // Fallback
    debugPrint("Widget: compute() not available → using synchronous resize.");
    return _resizeWorker({'bytes': bytes, 'maxBytes': maxBytes});
  }
}

Future<void> updateHomeWidget() async {
  try {
    debugPrint("Starting widget update process");

    // Fetch latest image ID
    final latest = await getLatestImage();
    final imageId = latest.data;
    if (imageId == null) {
      debugPrint("No latest image found → abort.");
      return;
    }
    debugPrint("Latest image ID: $imageId");

    // Download image bytes
    final imgResult = await getImage(imageId);
    final Uint8List? imageBytes = imgResult.data;

    if (imageBytes == null) {
      debugPrint("Image bytes null → abort.");
      return;
    }
    debugPrint("Downloaded image bytes: ${imageBytes.length}");

    // Fetch image details
    final details = await getImageDetails(imageId);
    final description = details.data?['description'] ?? "";
    final uploaderId = details.data?['uploaded_by'];
    final uploaderInfo = await getUserDetails(uploaderId);

    final uploaderName = uploaderInfo.data?.username ?? "Unknown";

    debugPrint("Uploader: $uploaderName");
    debugPrint("Description: $description");

    // Get widget bitmap limit
    int maxBytes = await UserPreferences.getWidgetBitmapLimit();
    if (maxBytes <= 0) {
      maxBytes = 10 * 1024 * 1024;
      debugPrint("Using fallback widget bitmap limit: 10 MB");
    } else {
      debugPrint("Widget bitmap limit: $maxBytes bytes");
    }

    // Downscale image to fit within android bitmap limits
    final resized = await _downscaleWidgetImage(imageBytes, maxBytes);
    debugPrint("Resized bytes: ${resized.length}");

    // Save file
    final dir = await getTemporaryDirectory();
    final path = "${dir.path}/krab_widget_current.jpg";
    final file = File(path);

    await file.writeAsBytes(resized, flush: true);

    debugPrint("Saved resized image → ${file.path} (${await file.length()} bytes)");

    // Save metadata to widget
    await HomeWidget.saveWidgetData('recentImageUrl', path);
    await HomeWidget.saveWidgetData('recentImageDescription', description);
    await HomeWidget.saveWidgetData('recentImageSender', uploaderName);
    
    // Update widget
    final updated = await HomeWidget.updateWidget(name: "HomeScreenWidget") ?? false;
    debugPrint("Widget update success: $updated");
    
    // Auto-save original image if enabled
    if (await UserPreferences.getAutoImageSave()) {
      await downloadImage(
        imageBytes,
        uploaderName,
        DateTime.now().toIso8601String(),
      );
    }

    debugPrint("Widget update process complete.");
  } catch (e, st) {
    debugPrint("Widget update failed: $e");
    debugPrint(st.toString());
  }
}