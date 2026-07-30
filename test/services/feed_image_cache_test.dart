import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/image_details.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/cache/feed_image_cache.dart';

SharedImage _photo(String id, {String instanceId = 'inst_1'}) =>
    SharedImage([ImageRef(instanceId: instanceId, id: id)]);

/// The same image on two instances, sharing an id minted at send time.
SharedImage _shared(String shareId, Map<String, String> idsByInstance) =>
    SharedImage([
      for (final entry in idsByInstance.entries)
        ImageRef(
          instanceId: entry.key,
          id: entry.value,
          shareId: shareId,
        )
    ]);

/// Serves made-up images and counts what was asked for, so the tests can tell a
/// cache hit from a fetch.
class _FakeFetchers implements ImageFetchers {
  final List<String> lowResFetches = [];
  final List<String> fullResFetches = [];
  final List<String> detailFetches = [];
  final List<String> userFetches = [];
  final List<String> commentCountFetches = [];

  /// The groupId the last comment count was asked for.
  String? lastCommentGroupId;

  int reactionTotal = 0;

  @override
  Future<Uint8List?> bytes(SharedImage image, {required bool lowRes}) async {
    final id = image.primary.id;
    (lowRes ? lowResFetches : fullResFetches).add(id);
    // Distinct bytes per image and resolution, so a mix-up is visible.
    return Uint8List.fromList('$id:${lowRes ? 'low' : 'full'}'.codeUnits);
  }

  /// The instance the last details call was asked to prefer.
  String? lastPreferredInstanceId;

  @override
  Future<DetailsFromCopy?> details(SharedImage image,
      {String? preferInstanceId}) async {
    detailFetches.add(image.primary.id);
    lastPreferredInstanceId = preferInstanceId;
    // Answer as the preferred copy when the image has one, the way a live
    // instance would: it is that copy's server the details came from.
    final copy = image.copies.firstWhere(
      (c) => c.instanceId == preferInstanceId,
      orElse: () => image.primary,
    );
    return (
      details: ImageDetails(
        uploadedBy: 'uploader-of-${copy.id}',
        createdAt: '2026-01-01T00:00:00Z',
        description: 'about ${copy.id}',
      ),
      copy: copy,
    );
  }

  @override
  Future<krab_user.User?> uploader(ImageRef copy, String userId) async {
    userFetches.add(userId);
    return krab_user.User(
      instanceId: copy.instanceId,
      id: userId,
      username: 'name-of-$userId',
    );
  }

  @override
  Future<int> commentCount(SharedImage image, String? groupId) async {
    commentCountFetches.add(image.primary.id);
    lastCommentGroupId = groupId;
    return 3;
  }

  @override
  Future<int> reactionCount(SharedImage image) async => reactionTotal;
}

/// Serves nothing, so failures can be exercised.
class _FailingFetchers extends _FakeFetchers {
  @override
  Future<Uint8List?> bytes(SharedImage image, {required bool lowRes}) async =>
      null;
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
      expect(_text(await cache.bytes(_photo('a'))), 'a:low');
      expect(_text(await cache.bytes(_photo('a'))), 'a:low');

      expect(fake.lowResFetches, ['a'], reason: 'the second read was a hit');
    });

    test('keeps the two resolutions apart', () async {
      expect(_text(await cache.bytes(_photo('a'), lowRes: true)), 'a:low');
      expect(_text(await cache.bytes(_photo('a'), lowRes: false)), 'a:full');

      expect(fake.lowResFetches, ['a']);
      expect(fake.fullResFetches, ['a']);
    });

    test('returns null when the fetch fails, and does not cache the failure',
        () async {
      final failing = FeedImageCache(fetchers: _FailingFetchers());
      expect(await failing.bytes(_photo('a')), isNull);
      expect(await failing.bytes(_photo('a')), isNull);
    });
  });

  group('imageData', () {
    test('hands back the same future rather than re-fetching', () async {
      final first = cache.imageData(_photo('a'));
      final second = cache.imageData(_photo('a'));
      expect(identical(first, second), isTrue);

      await first;
      expect(fake.detailFetches, ['a']);
    });

    test('fills in the uploader, comment count and reaction total', () async {
      fake.reactionTotal = 7;
      final data = await cache.imageData(_photo('a'));

      expect(data.uploadedBy, 'uploader-of-a');
      expect(data.description, 'about a');
      expect(cache.user(_photo('a'))?.username, 'name-of-uploader-of-a');
      expect(cache.commentCount(_photo('a')), 3);
      expect(cache.reactionCount(_photo('a')), 7);
    });

    test('asks for the per-group comment count in a group feed', () async {
      await cache.imageData(_photo('a'));
      expect(fake.lastCommentGroupId, 'g1');
    });

    test('asks across every group in the cross-group feed', () async {
      final crossGroup = FeedImageCache(fetchers: fake);
      await crossGroup.imageData(_photo('a'));
      expect(fake.lastCommentGroupId, isNull);
    });

    test('fetches an uploader once, however many of their images load',
        () async {
      // Two images, but _FakeFetchers gives each its own uploader, so force a
      // shared one by loading the same image twice after a byte-only drop.
      await cache.imageData(_photo('a'));
      cache.drop(_photo('a'));
      await cache.imageData(_photo('a'));

      expect(fake.userFetches, ['uploader-of-a'],
          reason: 'the uploader was already known');
    });

    test('does not re-fetch tallies for an image whose bytes were evicted',
        () async {
      await cache.imageData(_photo('a'));
      cache.drop(_photo('a'));
      await cache.imageData(_photo('a'));

      expect(fake.commentCountFetches, ['a'],
          reason: 'the count survives a byte eviction');
    });
  });

  group('memory bounds', () {
    test('keeps only the last maxImages thumbnails', () async {
      for (var i = 0; i < FeedImageCache.maxImages + 5; i++) {
        await cache.imageData(_photo('img$i'));
      }

      // The five oldest fell out of the window and must be re-fetched.
      expect(fake.lowResFetches.length, FeedImageCache.maxImages + 5);
      await cache.bytes(_photo('img0'));
      expect(fake.lowResFetches.where((id) => id == 'img0').length, 2);

      // While a recent one is still held.
      final recent = 'img${FeedImageCache.maxImages + 4}';
      await cache.bytes(_photo(recent));
      expect(fake.lowResFetches.where((id) => id == recent).length, 1);
    });

    test('holds far fewer full-resolution images than thumbnails', () async {
      for (var i = 0; i < FeedImageCache.maxFullResImages + 2; i++) {
        await cache.fullResBytes(_photo('img$i'));
      }

      // The first two originals were pushed out of the small window.
      await cache.bytes(_photo('img0'), lowRes: false);
      expect(fake.fullResFetches.where((id) => id == 'img0').length, 2);

      // The most recent original is still resident.
      final recent = 'img${FeedImageCache.maxFullResImages + 1}';
      await cache.bytes(_photo(recent), lowRes: false);
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
      await cache.imageData(_photo('a'));
      cache.addToCommentCount(_photo('a'), 2);

      cache.drop(_photo('a'));

      expect(cache.commentCount(_photo('a')), 5);
    });

    test('evict forgets an image entirely', () async {
      await cache.imageData(_photo('a'));
      cache.evict(_photo('a'));

      expect(cache.commentCount(_photo('a')), 0);
      expect(cache.reactionCount(_photo('a')), 0);
    });

    test('clear forgets everything, including uploaders', () async {
      await cache.imageData(_photo('a'));
      cache.clear();

      expect(cache.user(_photo('uploader-of-a')), isNull);
      expect(cache.commentCount(_photo('a')), 0);
    });
  });

  group('an image held on several servers', () {
    test('is one entry, however it is looked up', () async {
      final image = _shared('share-1', {'inst_1': 'a', 'inst_2': 'b'});

      await cache.imageData(image);
      await cache.imageData(image);

      expect(fake.lowResFetches, hasLength(1),
          reason: 'the second look-up is the same image, not another one');
    });

    test('is the same entry whichever copy was listed first', () async {
      // Two feeds can order the copies differently
      final fromOne = _shared('share-1', {'inst_1': 'a', 'inst_2': 'b'});
      final fromTwo = _shared('share-1', {'inst_2': 'b', 'inst_1': 'a'});

      cache.addToCommentCount(fromOne, 3);
      expect(cache.commentCount(fromTwo), 3,
          reason: 'the tallies belong to the image, not to a copy of it');

      await cache.imageData(fromOne);
      await cache.imageData(fromTwo);
      expect(fake.lowResFetches, hasLength(1),
          reason: 'and neither is the bytes fetched twice');
    });

    test('is a different entry from an unrelated image with the same id',
        () async {
      // Two servers can mint the same image id for two unrelated images.
      await cache.imageData(_photo('a', instanceId: 'inst_1'));
      await cache.imageData(_photo('a', instanceId: 'inst_2'));

      expect(fake.lowResFetches, hasLength(2),
          reason: 'an id only identifies an image together with its server');
    });
  });

  group('whose name an image is shown under', () {
    // The same person holds a different account on each server, so an image on
    // two of them has two uploaders and only one can be shown.
    final onBoth =
        _shared('share-1', {'inst_1': 'copy-a', 'inst_2': 'copy-b'});

    test('a gallery asks the server whose group it is showing', () async {
      final gallery = FeedImageCache(
          groupId: 'g1', instanceId: 'inst_2', fetchers: fake);

      final data = await gallery.imageData(onBoth);

      expect(fake.lastPreferredInstanceId, 'inst_2');
      expect(data.uploaderInstanceId, 'inst_2',
          reason: 'the account that posted it in *this* group');
      expect(data.uploadedBy, 'uploader-of-copy-b');
    });

    test('the cross-group feed has no such server and takes the primary',
        () async {
      final crossGroup = FeedImageCache(fetchers: fake);

      final data = await crossGroup.imageData(onBoth);

      expect(fake.lastPreferredInstanceId, isNull);
      expect(data.uploaderInstanceId, onBoth.primary.instanceId);
    });

    test('the uploader is looked up on the server the id came from', () async {
      final gallery = FeedImageCache(
          groupId: 'g1', instanceId: 'inst_2', fetchers: fake);

      await gallery.imageData(onBoth);

      expect(gallery.user(onBoth)?.instanceId, 'inst_2',
          reason: 'a user id names nobody without the server it is on');
      expect(gallery.user(onBoth)?.username, 'name-of-uploader-of-copy-b');
    });
  });

  test('addToCommentCount moves the tally in both directions', () {
    cache.addToCommentCount(_photo('a'), 1);
    cache.addToCommentCount(_photo('a'), 1);
    expect(cache.commentCount(_photo('a')), 2);

    cache.addToCommentCount(_photo('a'), -1);
    expect(cache.commentCount(_photo('a')), 1);
  });
}
