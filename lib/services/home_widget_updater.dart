import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';

import 'package:krab/filesaver.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/UserPreferences.dart';

// Resize image to fit within maxBytes
Uint8List _downsampleImageHomeWidget(Map<String, dynamic> args) {
  final Uint8List bytes = args['bytes'];
  final int maxBytes = args['maxBytes'];

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  debugPrint('Original bitmap: ${decoded.width}x${decoded.height}');
  final currentSize = decoded.width * decoded.height * 4;
  if (currentSize <= maxBytes) return bytes;

  final scale = sqrt(maxBytes / currentSize);
  final newWidth = max(1, (decoded.width * scale).round());
  final resized = img.copyResize(decoded, width: newWidth);

  debugPrint(
    'Resized for widget: ${decoded.width}x${decoded.height} to ${resized.width}x${resized.height}',
  );

  return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
}

// Run resizing in the background
Future<Uint8List> _downscaleImageHomeWidget(Uint8List bytes, int maxBytes) async {
  try {
    return await compute(_downsampleImageHomeWidget, {'bytes': bytes, 'maxBytes': maxBytes});
  } catch (e, st) {
    debugPrint('Downscale isolate failed: $e');
    debugPrint(st.toString());
    return bytes; // fallback: return original
  }
}

// Main function to update home widget
Future<void> updateHomeWidget() async {
  try {
    debugPrint("Starting home widget update...");

    // Get the latest image ID
    final response = await getLatestImage();
    final imageId = response.data;
    if (imageId == null) {
      debugPrint("No latest image found, aborting.");
      return;
    }
    debugPrint("Got latest image ID: $imageId");

    // Download image bytes
    final imageResponse = await getImage(imageId);
    final Uint8List? imageBytes = imageResponse.data;
    if (imageBytes == null) {
      debugPrint("⚠️ Image bytes are null, aborting.");
      return;
    }
    debugPrint("Retrieved image bytes: ${imageBytes.length} bytes");

    // Fetch metadata
    final imageDetails = await getImageDetails(imageId);
    final description = imageDetails.data?['description'] ?? '';
    final uploaderId = imageDetails.data?['uploaded_by'];
    final uploaderInfo = await getUserDetails(uploaderId);
    final uploaderName = uploaderInfo.data?.username ?? 'Unknown';

    debugPrint("Got image description: $description");
    debugPrint("Got image sender: $uploaderName");

    // Compute safe image size limit
    final maxBytes = await UserPreferences.getWidgetBitmapLimit();
    debugPrint("Widget bitmap size limit: $maxBytes bytes");
    final downscaledBytes = await _downscaleImageHomeWidget(imageBytes, maxBytes);
    debugPrint("Downscaled bytes length: ${downscaledBytes.length}");

    // Save downscaled image to temp
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/krab_widget_current.jpg');
    await file.writeAsBytes(downscaledBytes, flush: true);

    final fileSize = await file.length();
    debugPrint("Saved downscaled image: ${file.path} (${(fileSize / 1024).round()} KB)");

    // Store data for widget
    await HomeWidget.saveWidgetData<String>('recentImageUrl', file.path);
    await HomeWidget.saveWidgetData<String>('recentImageDescription', description);
    await HomeWidget.saveWidgetData<String>('recentImageSender', uploaderName);

    // Update the widgets
    final updated1 = await HomeWidget.updateWidget(name: 'HomeScreenWidget');
    final updated2 = await HomeWidget.updateWidget(name: 'HomeScreenWidgetWithText');
    debugPrint('Widget update results: Home=$updated1, Home+Text=$updated2');

    debugPrint("Widget updated successfully with image: ${file.path}");

    // Clean old temp images
    try {
      for (final f in dir.listSync().whereType<File>()) {
        if (f.path.contains('krab_image_') && !f.path.contains('krab_widget_current')) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint("Cleanup failed: $e");
    }

    // Optional auto-save
    final autoSave = await UserPreferences.getAutoImageSave();
    if (autoSave) {
      debugPrint("Auto-saving image to gallery...");
      await downloadImage(imageBytes, uploaderName, DateTime.now().toIso8601String());
    }
  } catch (e, st) {
    debugPrint("Error during widget update: $e");
    debugPrint(st.toString());
  }
}
