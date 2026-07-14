import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/storage_cleanup.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('krab_cleanup_test');
    StorageCleanup.overrideForTest(tempDir: () async => tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// A file with a chosen age, so the sweep's cutoff can be exercised.
  Future<File> write(String path, {Duration age = Duration.zero}) async {
    final file = File('${tmp.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(1024, 0));
    if (age > Duration.zero) {
      await file.setLastModified(DateTime.now().subtract(age));
    }
    return file;
  }

  test('deletes the APK the updater downloaded', () async {
    final apk = await write('app_update.apk', age: const Duration(hours: 1));

    await StorageCleanup.sweep();

    expect(await apk.exists(), isFalse);
  });

  test('spares an APK the installer may still be about to install', () async {
    final apk = await write('app_update.apk', age: const Duration(minutes: 2));

    await StorageCleanup.sweep();

    expect(await apk.exists(), isTrue);
  });

  test('collects that APK on a later start, once the prompt is long gone',
      () async {
    final apk = await write('app_update.apk', age: const Duration(minutes: 30));

    await StorageCleanup.sweep();

    expect(await apk.exists(), isFalse);
  });

  test('clears out what the image picker left behind', () async {
    final leftover =
        await write('a7f3-uuid/1000021955.jpg', age: const Duration(days: 30));

    await StorageCleanup.sweep();

    expect(await leftover.exists(), isFalse);
    expect(await leftover.parent.exists(), isFalse,
        reason: 'the emptied directory should go too');
  });

  test('leaves a pick that is still in flight alone', () async {
    final fresh = await write('a7f3-uuid/1000021955.jpg');

    await StorageCleanup.sweep();

    expect(await fresh.exists(), isTrue);
  });

  test('does not touch the caches that evict for themselves', () async {
    final cached =
        await write('image_cache/abc.full', age: const Duration(days: 400));
    final networkCache = await write('libCachedImageData/x.db',
        age: const Duration(days: 400));

    await StorageCleanup.sweep();

    expect(await cached.exists(), isTrue);
    expect(await networkCache.exists(), isTrue);
  });

  test('leaves notification images to their own pruner', () async {
    final notif = await write('notif_img_abc.jpg', age: const Duration(days: 30));

    await StorageCleanup.sweep();

    expect(await notif.exists(), isTrue);
  });

  test('an empty temporary directory is not an error', () async {
    await StorageCleanup.sweep();
    expect(await tmp.exists(), isTrue);
  });
}
