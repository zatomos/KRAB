import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// On-disk cache for image bytes downloaded from storage.
///
/// Images are immutable, as they're keyed by a per-photo UUID. Their bytes
/// never change, so entries are kept until evicted for space.
/// Best-effort throughout: any I/O failure is swallowed and simply behaves
/// as a cache miss.
///
/// Sits behind `getImage`, so the feed, viewer, and home-screen widget all share
/// it. Writes are atomic so a reader never sees a partial file.
class ImageDiskCache {
  ImageDiskCache._();
  static final ImageDiskCache instance = ImageDiskCache._();

  static const int _maxBytes = 50 * 1024 * 1024; // 50 MB

  // Pruning stats every file, so throttle it rather than running per write.
  static const Duration _pruneInterval = Duration(minutes: 2);

  Directory? _dir;
  Future<Directory>? _dirFuture;
  DateTime? _lastPrune;
  bool _pruning = false;
  final Set<String> _writing = {};

  Future<Directory> _ensureDir() {
    final existing = _dir;
    if (existing != null) return Future.value(existing);
    return _dirFuture ??= () async {
      final base = await getApplicationCacheDirectory();
      final dir = Directory('${base.path}/image_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    }();
  }

  File _fileFor(Directory dir, String key) => File('${dir.path}/$key');

  /// Cached bytes for [key], or null if absent. Touches the file's mtime so
  /// frequently-read entries are the last to be evicted.
  Future<Uint8List?> read(String key) async {
    try {
      final file = _fileFor(await _ensureDir(), key);
      if (!await file.exists()) {
        debugPrint('[img-cache] MISS $key');
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        debugPrint('[img-cache] MISS $key (empty file)');
        return null;
      }
      unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
      debugPrint('[img-cache] HIT $key (${(bytes.length / 1024).round()} KB)');
      return bytes;
    } catch (e) {
      debugPrint('[img-cache] read error $key: $e');
      return null;
    }
  }

  /// Writes [bytes] for [key], then schedules a throttled prune. The write goes
  /// to a temp file and is renamed into place so a concurrent read never sees a
  /// half-written file.
  Future<void> write(String key, Uint8List bytes) async {
    if (bytes.isEmpty || _writing.contains(key)) return;
    _writing.add(key);
    try {
      final dir = await _ensureDir();
      final tmp = _fileFor(dir, '$key.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(_fileFor(dir, key).path);
      debugPrint('[img-cache] WROTE $key (${(bytes.length / 1024).round()} KB)');
    } catch (e) {
      debugPrint('[img-cache] write error $key: $e');
    } finally {
      _writing.remove(key);
    }
    unawaited(_maybePrune());
  }

  /// Remove both variants (low/full) of a single image
  Future<void> remove(String imageId) async {
    try {
      final dir = await _ensureDir();
      for (final key in ['$imageId.low', '$imageId.full']) {
        final file = _fileFor(dir, key);
        if (await file.exists()) await file.delete();
      }
      debugPrint('[img-cache] REMOVED $imageId');
    } catch (_) {
      // best-effort
    }
  }

  /// Delete the whole cache.
  Future<void> clear() async {
    try {
      final dir = await _ensureDir();
      if (await dir.exists()) await dir.delete(recursive: true);
      debugPrint('[img-cache] CLEARED');
    } catch (_) {
    } finally {
      _dir = null;
      _dirFuture = null;
      _lastPrune = null;
    }
  }

  /// Evict least-recently-used files until under [_maxBytes].
  /// Throttled to [_pruneInterval] and never runs concurrently with itself.
  Future<void> _maybePrune() async {
    if (_pruning) return;
    final now = DateTime.now();
    if (_lastPrune != null && now.difference(_lastPrune!) < _pruneInterval) {
      return;
    }
    _lastPrune = now;
    _pruning = true;
    try {
      final dir = await _ensureDir();
      final files = <(File, int, DateTime)>[];
      int total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          files.add((entity, stat.size, stat.modified));
          total += stat.size;
        } catch (_) {}
      }
      final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
      if (total <= _maxBytes) {
        debugPrint('[img-cache] prune: ${files.length} files, '
            '$totalMb MB, under cap');
        return;
      }
      debugPrint('[img-cache] prune: ${files.length} files, $totalMb MB, '
          'over cap: evicting');
      files.sort((a, b) => a.$3.compareTo(b.$3)); // oldest first
      var evicted = 0;
      for (final (file, size, _) in files) {
        if (total <= _maxBytes) break;
        try {
          await file.delete();
          total -= size;
          evicted++;
        } catch (_) {}
      }
      debugPrint('[img-cache] pruned $evicted files, now '
          '${(total / 1024 / 1024).toStringAsFixed(1)} MB');
    } catch (_) {
      // best-effort
    } finally {
      _pruning = false;
    }
  }
}
