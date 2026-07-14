import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/upload_outbox.dart';

/// A stand-in for the server. Records what it was asked to send and answers
/// with whatever the test lined up.
class _FakeSender {
  final List<String> sentDescriptions = [];
  final List<List<String>> sentGroups = [];

  /// The id each call was asked to resume under, null when it opened a new send.
  final List<String?> resumedWith = [];

  /// Ids this fake "reserved", one per call that had to open a new send. Stands
  /// in for request_image_upload minting a fresh id.
  final List<String> reserved = [];

  /// Whether a call should reserve an id before answering, the way a real send
  /// does before it uploads.
  bool reservesBeforeAnswering = true;

  /// Answers, one per call. The last one repeats once they run out.
  List<SupabaseResponse<String>> responses = [
    SupabaseResponse(success: true, data: 'image-1'),
  ];
  int calls = 0;

  Future<SupabaseResponse<String>> send(
    File file,
    List<String> groupIds,
    String description, {
    String? resumeImageId,
    Future<void> Function(String imageId)? onReserved,
  }) async {
    sentDescriptions.add(description);
    sentGroups.add(groupIds);
    resumedWith.add(resumeImageId);

    if (resumeImageId == null && reservesBeforeAnswering) {
      final id = 'reserved-${reserved.length}';
      reserved.add(id);
      // Awaited, as the real send does: the id must be on disk before the bytes
      // could possibly land under it.
      await onReserved?.call(id);
    }

    final response = responses[calls.clamp(0, responses.length - 1)];
    calls++;
    return response;
  }
}

SupabaseResponse<String> _offline() =>
    SupabaseResponse(success: false, offline: true, error: 'no connection');

SupabaseResponse<String> _rejected() =>
    SupabaseResponse(success: false, error: 'Image not found or permission denied');

void main() {
  late Directory tempDir;
  late _FakeSender sender;
  late int retriesScheduled;
  late int widgetRefreshes;

  /// A throwaway photo to queue.
  Future<File> photo(String name) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes([1, 2, 3]);
    return file;
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});

    tempDir = await Directory.systemTemp.createTemp('krab_outbox_test');
    sender = _FakeSender();
    retriesScheduled = 0;
    widgetRefreshes = 0;

    UploadOutbox.instance.overrideForTest(
      sender: sender.send,
      storageDir: () async => Directory('${tempDir.path}/outbox'),
      scheduleRetry: () async => retriesScheduled++,
      onDelivered: () async => widgetRefreshes++,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a queued photo is sent on the next flush, then dropped', () async {
    await UploadOutbox.instance.enqueue(await photo('a.jpg'), ['g1'], 'hello');

    expect(await UploadOutbox.instance.pendingCount(), 1);
    expect(retriesScheduled, 1, reason: 'enqueue asks the platform to retry');

    final drained = await UploadOutbox.instance.flush();

    expect(drained, isTrue);
    expect(sender.calls, 1);
    expect(sender.sentDescriptions, ['hello']);
    expect(sender.sentGroups, [
      ['g1']
    ]);
    expect(await UploadOutbox.instance.pendingCount(), 0);
    expect(widgetRefreshes, 1, reason: 'the delivered photo belongs on the widget');
  });

  test('a flush that sends nothing leaves the widget alone', () async {
    sender.responses = [_offline()];
    await UploadOutbox.instance.enqueue(await photo('z.jpg'), ['g1'], 'held');

    await UploadOutbox.instance.flush();

    expect(widgetRefreshes, 0);
  });

  test('the photo bytes survive the original file being cleared away', () async {
    final original = await photo('b.jpg');
    await UploadOutbox.instance.enqueue(original, ['g1'], 'caption');

    // The camera writes captures to a cache directory the OS is free to purge.
    await original.delete();

    expect(await UploadOutbox.instance.flush(), isTrue);
    expect(sender.calls, 1);
  });

  test('sent photos have their copy of the bytes deleted', () async {
    await UploadOutbox.instance.enqueue(await photo('c.jpg'), ['g1'], '');
    final stored = Directory('${tempDir.path}/outbox').listSync();
    expect(stored, hasLength(1));

    await UploadOutbox.instance.flush();

    expect(Directory('${tempDir.path}/outbox').listSync(), isEmpty);
  });

  test('an offline flush keeps the photo queued and reports failure', () async {
    sender.responses = [_offline()];
    await UploadOutbox.instance.enqueue(await photo('d.jpg'), ['g1'], 'held');

    final drained = await UploadOutbox.instance.flush();

    expect(drained, isFalse, reason: 'a failed flush earns a WorkManager retry');
    expect(await UploadOutbox.instance.pendingCount(), 1);
  });

  test('a photo queued offline goes out once the connection is back', () async {
    sender.responses = [_offline()];
    await UploadOutbox.instance.enqueue(await photo('e.jpg'), ['g1'], 'later');

    expect(await UploadOutbox.instance.flush(), isFalse);
    expect(await UploadOutbox.instance.pendingCount(), 1);

    sender.responses = [SupabaseResponse(success: true, data: 'image-9')];

    expect(await UploadOutbox.instance.flush(), isTrue);
    expect(await UploadOutbox.instance.pendingCount(), 0);
  });

  test('one offline send stops the flush, leaving the rest for the retry',
      () async {
    sender.responses = [_offline()];
    await UploadOutbox.instance.enqueue(await photo('f.jpg'), ['g1'], 'one');
    await UploadOutbox.instance.enqueue(await photo('g.jpg'), ['g1'], 'two');

    await UploadOutbox.instance.flush();

    expect(sender.calls, 1,
        reason: 'if one send cannot reach the server, neither can the next');
    expect(await UploadOutbox.instance.pendingCount(), 2);
  });

  test('an offline flush hands back the claims on the photos it never reached',
      () async {
    sender.responses = [_offline()];
    await UploadOutbox.instance.enqueue(await photo('f.jpg'), ['g1'], 'one');
    await UploadOutbox.instance.enqueue(await photo('g.jpg'), ['g1'], 'two');

    await UploadOutbox.instance.flush();
    expect(sender.calls, 1);

    sender.responses = [SupabaseResponse(success: true, data: 'image-1')];

    expect(await UploadOutbox.instance.flush(), isTrue,
        reason: 'the connection is back; nothing should still be claimed');
    expect(sender.sentDescriptions, ['one', 'one', 'two']);
    expect(await UploadOutbox.instance.pendingCount(), 0);
  });

  test('a photo nobody could send for a week is dropped, offline or not',
      () async {
    // Being offline does not count against the attempt cap, but it cannot buy
    // unlimited time either, or a photo from a long-dead outing would still be
    // trying to go out.
    sender.responses = [_offline()];
    await UploadOutbox.instance.enqueue(await photo('old.jpg'), ['g1'], 'stale');

    // Backdate the entry past the 7-day cap, as if it had been queued then.
    final prefs = await SharedPreferences.getInstance();
    final entry =
        jsonDecode(prefs.getStringList('uploadOutbox')!.single) as Map<String, dynamic>;
    entry['createdAt'] = DateTime.now()
        .subtract(const Duration(days: 8))
        .toIso8601String();
    await prefs.setStringList('uploadOutbox', [jsonEncode(entry)]);

    await UploadOutbox.instance.flush();

    expect(await UploadOutbox.instance.pendingCount(), 0);
    expect(Directory('${tempDir.path}/outbox').listSync(), isEmpty,
        reason: 'an abandoned photo must not leave its bytes behind');
  });

  test('a photo the server refuses is dropped rather than retried forever',
      () async {
    sender.responses = [_rejected()];
    await UploadOutbox.instance.enqueue(await photo('h.jpg'), ['g1'], 'bad');

    // Each flush is one attempt; the cap is 10.
    for (var i = 0; i < 10; i++) {
      await UploadOutbox.instance.flush();
    }

    expect(sender.calls, 10);
    expect(await UploadOutbox.instance.pendingCount(), 0);
    expect(Directory('${tempDir.path}/outbox').listSync(), isEmpty,
        reason: 'an abandoned photo must not leave its bytes behind');
  });

  test('being offline does not burn attempts against the give-up cap', () async {
    sender.responses = [_offline()];
    await UploadOutbox.instance.enqueue(await photo('i.jpg'), ['g1'], 'patient');

    // Far more offline flushes than the attempt cap.
    for (var i = 0; i < 15; i++) {
      await UploadOutbox.instance.flush();
    }
    expect(await UploadOutbox.instance.pendingCount(), 1,
        reason: 'a photo must not be dropped just for waiting out a long outage');

    sender.responses = [SupabaseResponse(success: true, data: 'image-2')];
    expect(await UploadOutbox.instance.flush(), isTrue);
  });

  group('not sending the same photo twice', () {
    test('a retry resumes under the id the first attempt reserved', () async {
      sender.responses = [_offline()];
      await UploadOutbox.instance.enqueue(await photo('r1.jpg'), ['g1'], 'once');

      // First attempt reserves an id, then loses the connection mid-upload.
      await UploadOutbox.instance.flush();
      expect(sender.resumedWith, [null], reason: 'the first attempt opens a send');
      expect(sender.reserved, ['reserved-0']);

      // The retry must go up under that same id, not open a second send.
      sender.responses = [SupabaseResponse(success: true, data: 'reserved-0')];
      expect(await UploadOutbox.instance.flush(), isTrue);

      expect(sender.resumedWith, [null, 'reserved-0']);
      expect(sender.reserved, ['reserved-0'],
          reason: 'reserving a second id would send the photo twice');
    });

    test('the reserved id is written to disk, not just held in memory', () async {
      // Nothing in memory survives the process being killed, and the bytes may
      // already be in storage under that id. If it were only in memory, the next
      // launch would open a second send and the photo would go out twice.
      sender.responses = [_offline()];
      await UploadOutbox.instance
          .enqueue(await photo('r2.jpg'), ['g1'], 'crash');
      await UploadOutbox.instance.flush();

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final stored = (prefs.getStringList('uploadOutbox') ?? [])
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .toList();

      expect(stored, hasLength(1));
      expect(stored.single['reservedImageId'], 'reserved-0');
    });

    test('a send the server rejects starts clean, rather than retrying a dead id',
        () async {
      sender.responses = [_rejected()];
      await UploadOutbox.instance.enqueue(await photo('r3.jpg'), ['g1'], 'bad');

      await UploadOutbox.instance.flush();
      expect(sender.resumedWith, [null]);

      // The reservation may be exactly what the server objected to (an abandoned
      // one is swept after an hour), so the next attempt opens a fresh send.
      await UploadOutbox.instance.flush();
      expect(sender.resumedWith, [null, null]);
    });

    test('a photo queued after a failed upload keeps that upload\'s id', () async {
      // What SendImageDialog does: the send reserved an id, then went offline,
      // so the photo is queued carrying it. The bytes may already be in storage.
      await UploadOutbox.instance.enqueue(
        await photo('r4.jpg'),
        ['g1'],
        'maybe landed',
        reservedImageId: 'already-reserved',
      );

      await UploadOutbox.instance.flush();

      expect(sender.resumedWith, ['already-reserved']);
      expect(sender.reserved, isEmpty,
          reason: 'it must not open a second send for a photo that may be sent');
    });
  });

  test('flushing an empty outbox is a no-op success', () async {
    expect(await UploadOutbox.instance.flush(), isTrue);
    expect(sender.calls, 0);
  });

  test('several queued photos all go out in one flush', () async {
    await UploadOutbox.instance.enqueue(await photo('j.jpg'), ['g1'], 'first');
    await UploadOutbox.instance.enqueue(await photo('k.jpg'), ['g2'], 'second');

    expect(await UploadOutbox.instance.flush(), isTrue);

    expect(sender.sentDescriptions, ['first', 'second']);
    expect(await UploadOutbox.instance.pendingCount(), 0);
  });
}
