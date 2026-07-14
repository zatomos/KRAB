import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/image_details.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/cache/feed_image_cache.dart';

/// Serves made-up images and counts what was asked for, so the tests can tell a
/// cache hit from a fetch.
class _FakeFetchers extends ImageFetchers {
  final List<String> lowResFetches = [];
  final List<String> fullResFetches = [];
  final List<String> detailFetches = [];
  final List<String> userFetches = [];
  final List<String> commentCountFetches = [];

  /// The groupId the last comment count was asked for.
  String? lastCommentGroupId;

  int reactionTotal = 0;

  @override
  Future<SupabaseResponse<Uint8List>> image(String imageId,
      {bool lowRes = false}) async {
    (lowRes ? lowResFetches : fullResFetches).add(imageId);
    // Distinct bytes per image and resolution, so a mix-up is visible.
    return SupabaseResponse(
      success: true,
      data: Uint8List.fromList('$imageId:${lowRes ? 'low' : 'full'}'.codeUnits),
    );
  }

  @override
  Future<SupabaseResponse<ImageDetails>> details(String imageId) async {
    detailFetches.add(imageId);
    return SupabaseResponse(
      success: true,
      data: ImageDetails(
        uploadedBy: 'uploader-of-$imageId',
        createdAt: '2026-01-01T00:00:00Z',
        description: 'about $imageId',
      ),
    );
  }

  @override
  Future<SupabaseResponse<krab_user.User>> user(String userId) async {
    userFetches.add(userId);
    return SupabaseResponse(
      success: true,
      data: krab_user.User(id: userId, username: 'name-of-$userId'),
    );
  }

  @override
  Future<SupabaseResponse<int>> commentCount(
      String imageId, String? groupId) async {
    commentCountFetches.add(imageId);
    lastCommentGroupId = groupId;
    return const SupabaseResponse(success: true, data: 3);
  }

  @override
  Future<SupabaseResponse<List<dynamic>>> reactions(String imageId) async {
    return SupabaseResponse(
      success: true,
      data: [
        {'emoji': '👍', 'count': reactionTotal},
      ],
    );
  }
}

/// Serves nothing, so failures can be exercised.
class _FailingFetchers extends ImageFetchers {
  @override
  Future<SupabaseResponse<Uint8List>> image(String imageId,
          {bool lowRes = false}) async =>
      const SupabaseResponse(success: false, error: errorNetwork);
}

String _text(Uint8List? bytes) => String.fromCharCodes(bytes!);

void main() {
  late _FakeFetchers fake;
  late FeedImageCache cache;

  setUp(() {
    fake = _FakeFetchers();
    cache = FeedImageCache(groupId: 'g1', fetchers: fake);
  });

  group('bytes', () {
    test('fetches once, then serves from memory', () async {
      expect(_text(await cache.bytes('a')), 'a:low');
      expect(_text(await cache.bytes('a')), 'a:low');

      expect(fake.lowResFetches, ['a'], reason: 'the second read was a hit');
    });

    test('keeps the two resolutions apart', () async {
      expect(_text(await cache.bytes('a', lowRes: true)), 'a:low');
      expect(_text(await cache.bytes('a', lowRes: false)), 'a:full');

      expect(fake.lowResFetches, ['a']);
      expect(fake.fullResFetches, ['a']);
    });

    test('returns null when the fetch fails, and does not cache the failure',
        () async {
      final failing = FeedImageCache(fetchers: _FailingFetchers());
      expect(await failing.bytes('a'), isNull);
      expect(await failing.bytes('a'), isNull);
    });
  });

  group('imageData', () {
    test('hands back the same future rather than re-fetching', () async {
      final first = cache.imageData('a');
      final second = cache.imageData('a');
      expect(identical(first, second), isTrue);

      await first;
      expect(fake.detailFetches, ['a']);
    });

    test('fills in the uploader, comment count and reaction total', () async {
      fake.reactionTotal = 7;
      final data = await cache.imageData('a');

      expect(data.uploadedBy, 'uploader-of-a');
      expect(data.description, 'about a');
      expect(cache.user('uploader-of-a')?.username, 'name-of-uploader-of-a');
      expect(cache.commentCount('a'), 3);
      expect(cache.reactionCount('a'), 7);
    });

    test('asks for the per-group comment count in a group feed', () async {
      await cache.imageData('a');
      expect(fake.lastCommentGroupId, 'g1');
    });

    test('asks across every group in the cross-group feed', () async {
      final crossGroup = FeedImageCache(fetchers: fake);
      await crossGroup.imageData('a');
      expect(fake.lastCommentGroupId, isNull);
    });

    test('fetches an uploader once, however many of their photos load',
        () async {
      // Two images, but _FakeFetchers gives each its own uploader, so force a
      // shared one by loading the same image twice after a byte-only drop.
      await cache.imageData('a');
      cache.drop('a');
      await cache.imageData('a');

      expect(fake.userFetches, ['uploader-of-a'],
          reason: 'the uploader was already known');
    });

    test('does not re-fetch tallies for an image whose bytes were evicted',
        () async {
      await cache.imageData('a');
      cache.drop('a');
      await cache.imageData('a');

      expect(fake.commentCountFetches, ['a'],
          reason: 'the count survives a byte eviction');
    });
  });

  group('memory bounds', () {
    test('keeps only the last maxImages thumbnails', () async {
      for (var i = 0; i < FeedImageCache.maxImages + 5; i++) {
        await cache.imageData('img$i');
      }

      // The five oldest fell out of the window and must be re-fetched.
      expect(fake.lowResFetches.length, FeedImageCache.maxImages + 5);
      await cache.bytes('img0');
      expect(fake.lowResFetches.where((id) => id == 'img0').length, 2);

      // While a recent one is still held.
      final recent = 'img${FeedImageCache.maxImages + 4}';
      await cache.bytes(recent);
      expect(fake.lowResFetches.where((id) => id == recent).length, 1);
    });

    test('holds far fewer full-resolution photos than thumbnails', () async {
      for (var i = 0; i < FeedImageCache.maxFullResImages + 2; i++) {
        await cache.fullResBytes('img$i');
      }

      // The first two originals were pushed out of the small window.
      await cache.bytes('img0', lowRes: false);
      expect(fake.fullResFetches.where((id) => id == 'img0').length, 2);

      // The most recent original is still resident.
      final recent = 'img${FeedImageCache.maxFullResImages + 1}';
      await cache.bytes(recent, lowRes: false);
      expect(fake.fullResFetches.where((id) => id == recent).length, 1);
    });

    test('the full-res window is much smaller than the thumbnail window', () {
      expect(FeedImageCache.maxFullResImages,
          lessThan(FeedImageCache.maxImages ~/ 4),
          reason: 'originals are uncompressed and would otherwise OOM the app');
    });
  });

  group('eviction', () {
    test('drop forgets the bytes but keeps the tallies', () async {
      await cache.imageData('a');
      cache.addToCommentCount('a', 2);

      cache.drop('a');

      expect(cache.commentCount('a'), 5);
    });

    test('evict forgets an image entirely', () async {
      await cache.imageData('a');
      cache.evict('a');

      expect(cache.commentCount('a'), 0);
      expect(cache.reactionCount('a'), 0);
    });

    test('clear forgets everything, including uploaders', () async {
      await cache.imageData('a');
      cache.clear();

      expect(cache.user('uploader-of-a'), isNull);
      expect(cache.commentCount('a'), 0);
    });
  });

  test('addToCommentCount moves the tally in both directions', () {
    cache.addToCommentCount('a', 1);
    cache.addToCommentCount('a', 1);
    expect(cache.commentCount('a'), 2);

    cache.addToCommentCount('a', -1);
    expect(cache.commentCount('a'), 1);
  });
}
