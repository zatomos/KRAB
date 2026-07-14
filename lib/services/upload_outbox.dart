import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/home_widget_updater.dart';

/// WorkManager task name for a flush, and the unique name that keeps at most
/// one flush scheduled at a time.
const String outboxFlushTask = 'outboxFlush';
const String _outboxFlushUniqueName = 'outbox_flush';

const String _outboxPrefsKey = 'uploadOutbox';

/// Photos are dropped rather than retried forever
const int _maxAttempts = 10;
const Duration _maxAge = Duration(days: 7);

/// How long a claim by one isolate is honored by the other. The app and the
/// background worker can both flush; a claim stops them sending the same photo
/// twice, and expires so a worker killed mid-send doesn't strand it.
const Duration _claimTimeout = Duration(minutes: 5);

/// A photo waiting to go out, and its copy of the image bytes.
class _OutboxEntry {
  final String id;
  final String path;
  final List<String> groupIds;
  final String description;
  final DateTime createdAt;
  final int attempts;
  final DateTime? claimedAt;

  /// The id the server reserved for this photo, once a send has got that far.
  ///
  /// Retrying under the same id is what keeps a retry from becoming a second
  /// photo.
  final String? reservedImageId;

  const _OutboxEntry({
    required this.id,
    required this.path,
    required this.groupIds,
    required this.description,
    required this.createdAt,
    this.attempts = 0,
    this.claimedAt,
    this.reservedImageId,
  });

  _OutboxEntry copyWith({
    int? attempts,
    DateTime? claimedAt,
    bool clearClaim = false,
    String? reservedImageId,
    bool clearReservation = false,
  }) =>
      _OutboxEntry(
        id: id,
        path: path,
        groupIds: groupIds,
        description: description,
        createdAt: createdAt,
        attempts: attempts ?? this.attempts,
        claimedAt: clearClaim ? null : (claimedAt ?? this.claimedAt),
        reservedImageId: clearReservation
            ? null
            : (reservedImageId ?? this.reservedImageId),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'groupIds': groupIds,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
        'attempts': attempts,
        'claimedAt': claimedAt?.toIso8601String(),
        'reservedImageId': reservedImageId,
      };

  static _OutboxEntry? fromJson(Map<String, dynamic> json) {
    try {
      final claimedAt = json['claimedAt'] as String?;
      return _OutboxEntry(
        id: json['id'] as String,
        path: json['path'] as String,
        groupIds: (json['groupIds'] as List).cast<String>(),
        description: json['description'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        attempts: json['attempts'] as int? ?? 0,
        claimedAt: claimedAt == null ? null : DateTime.parse(claimedAt),
        reservedImageId: json['reservedImageId'] as String?,
      );
    } catch (error) {
      debugPrint("Outbox: dropping unreadable entry: $error");
      return null;
    }
  }
}

/// Sends one queued photo.
typedef ImageSender = Future<SupabaseResponse<String>> Function(
  File imageFile,
  List<String> groupIds,
  String description, {
  String? resumeImageId,
  Future<void> Function(String imageId)? onReserved,
});

/// Photos that couldn't be sent because the device was offline, held until it
/// can.
class UploadOutbox {
  UploadOutbox._();
  static final UploadOutbox instance = UploadOutbox._();

  bool _flushing = false;
  int _nextId = 0;

  ImageSender _sender = sendImageToGroups;

  Future<Directory> Function() _storageDir = () async =>
      Directory("${(await getApplicationSupportDirectory()).path}/outbox");

  Future<void> Function() _scheduleRetry = () => Workmanager().registerOneOffTask(
        _outboxFlushUniqueName,
        outboxFlushTask,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        backoffPolicy: BackoffPolicy.exponential,
        initialDelay: const Duration(seconds: 10),
      );

  Future<void> Function() _onDelivered = updateHomeWidget;


  @visibleForTesting
  void overrideForTest({
    ImageSender? sender,
    Future<Directory> Function()? storageDir,
    Future<void> Function()? scheduleRetry,
    Future<void> Function()? onDelivered,
  }) {
    if (sender != null) _sender = sender;
    if (storageDir != null) _storageDir = storageDir;
    if (scheduleRetry != null) _scheduleRetry = scheduleRetry;
    if (onDelivered != null) _onDelivered = onDelivered;
  }

  /// Queue a photo for sending once the device is back online, and ask
  /// WorkManager to retry as soon as it has a connection.
  ///
  /// Pass reservedImageId when the failed send already got an id out of the
  /// server: the retry has to reuse it, since the bytes may have landed and only
  /// the reply been lost.
  Future<void> enqueue(
    File imageFile,
    List<String> groupIds,
    String description, {
    String? reservedImageId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await _read(prefs);

    // The counter keeps two photos queued in the same microsecond apart.
    final id = "${DateTime.now().microsecondsSinceEpoch}-${_nextId++}";
    final dir = await _storageDir();
    await dir.create(recursive: true);
    final stored = await imageFile.copy("${dir.path}/$id.jpg");

    entries.add(_OutboxEntry(
      id: id,
      path: stored.path,
      groupIds: groupIds,
      description: description,
      reservedImageId: reservedImageId,
      createdAt: DateTime.now(),
    ));

    await _write(prefs, entries);
    debugPrint("Outbox: queued $id (${entries.length} pending)");

    await _scheduleRetry();
  }

  Future<int> pendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (await _read(prefs)).length;
  }

  /// Try to send everything queued. Returns true when the outbox is empty
  /// afterwards, which is what the background worker reports as success.
  ///
  /// Stops at the first offline failure: if one send can't reach the server the
  /// next one can't either, and every attempt costs a retry against the cap.
  Future<bool> flush() async {
    if (_flushing) return false;
    _flushing = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      var entries = await _read(prefs);
      if (entries.isEmpty) return true;

      final now = DateTime.now();

      // Take the entries nobody else is working on, and mark them so the other
      // isolate leaves them alone while we do.
      final mine = <String>{};
      entries = entries.map((entry) {
        final claim = entry.claimedAt;
        if (claim != null && now.difference(claim) < _claimTimeout) return entry;
        mine.add(entry.id);
        return entry.copyWith(claimedAt: now);
      }).toList();

      if (mine.isEmpty) {
        debugPrint("Outbox: every entry is claimed elsewhere, skipping");
        return false;
      }
      await _write(prefs, entries);

      final pending = entries.where((e) => mine.contains(e.id)).toList();

      for (var i = 0; i < pending.length; i++) {
        final entry = pending[i];

        // Resume under the id an earlier attempt reserved, so a retry can never
        // become a second photo. A fresh id is written down the instant it
        // exists: if we die between reserving it and finishing, the next attempt
        // has to find it, or it would reserve another and send the photo twice.
        var reserved = entry.reservedImageId;

        final response = await _sender(
          File(entry.path),
          entry.groupIds,
          entry.description,
          resumeImageId: reserved,
          onReserved: (imageId) async {
            reserved = imageId;
            await _update(prefs, entry.copyWith(reservedImageId: imageId));
          },
        );

        if (response.success) {
          debugPrint("Outbox: sent ${entry.id}");
          await _resolve(prefs, entry);
          continue;
        }

        final offline = response.offline;
        final attempts = entry.attempts + 1;
        final expired = now.difference(entry.createdAt) > _maxAge;

        // An offline failure isn't the photo's fault, so it doesn't count
        // against the attempt cap. Age still does: a photo nobody has been able
        // to send for a week is not going out now.
        if (expired || (!offline && attempts >= _maxAttempts)) {
          debugPrint("Outbox: giving up on ${entry.id}: ${response.error}");
          await _resolve(prefs, entry);
          continue;
        }

        debugPrint("Outbox: ${entry.id} not sent "
            "(attempt $attempts, offline=$offline): ${response.error}");

        // Keep the reservation while we're offline: the same id has to be
        // reused once the connection is back. A failure the server gave us is
        // different, the reservation may be the thing that's wrong with it,
        // so let the next attempt open a fresh send rather than retrying a
        // dead id until the cap runs out.
        await _update(
          prefs,
          entry.copyWith(
            attempts: offline ? entry.attempts : attempts,
            clearClaim: true,
            reservedImageId: offline ? reserved : null,
            clearReservation: !offline,
          ),
        );

        // One send that couldn't reach the server means the next can't either,
        // so stop here.
        if (offline) {
          for (final skipped in pending.skip(i + 1)) {
            await _update(prefs, skipped.copyWith(clearClaim: true));
          }
          break;
        }
      }

      final remaining = (await _read(prefs)).length;
      // Something left the queue, so the feed the widget shows has moved on.
      if (remaining < entries.length) await _onDelivered();
      return remaining == 0;
    } catch (error, stack) {
      debugPrint("Outbox: flush failed: $error\n$stack");
      return false;
    } finally {
      _flushing = false;
    }
  }

  /// Drop a finished entry, sent or abandoned, and the image bytes with it.
  Future<void> _resolve(SharedPreferences prefs, _OutboxEntry entry) async {
    final entries = await _read(prefs);
    entries.removeWhere((e) => e.id == entry.id);
    await _write(prefs, entries);

    try {
      final file = File(entry.path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint("Outbox: could not delete ${entry.path}: $error");
    }
  }

  Future<void> _update(SharedPreferences prefs, _OutboxEntry entry) async {
    final entries = await _read(prefs);
    final index = entries.indexWhere((e) => e.id == entry.id);
    if (index == -1) return;
    entries[index] = entry;
    await _write(prefs, entries);
  }

  /// Read the queue from disk. Reloads first: the other isolate may have written
  /// since this one last looked, and its in-memory copy would be stale.
  Future<List<_OutboxEntry>> _read(SharedPreferences prefs) async {
    await prefs.reload();
    final raw = prefs.getStringList(_outboxPrefsKey) ?? [];
    return raw
        .map((s) {
          try {
            return _OutboxEntry.fromJson(jsonDecode(s) as Map<String, dynamic>);
          } catch (error) {
            debugPrint("Outbox: dropping unreadable entry: $error");
            return null;
          }
        })
        .whereType<_OutboxEntry>()
        .toList();
  }

  Future<void> _write(SharedPreferences prefs, List<_OutboxEntry> entries) async {
    await prefs.setStringList(
      _outboxPrefsKey,
      entries.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }
}
