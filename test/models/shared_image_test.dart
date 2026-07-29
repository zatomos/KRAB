import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';

ImageRef ref(
  String instanceId,
  String id, {
  String? shareId,
  DateTime? uploadedAt,
}) =>
    ImageRef(
      instanceId: instanceId,
      id: id,
      shareId: shareId,
      uploadedAt: uploadedAt,
    );

void main() {
  group('mergeImages', () {
    test('collapses one send across two instances into one image', () {
      final images = mergeImages(
        [
          ref('a', 'img-a', shareId: 'share-1'),
          ref('b', 'img-b', shareId: 'share-1'),
        ],
        instanceOrder: ['a', 'b'],
      );

      expect(images, hasLength(1));
      expect(images.single.isShared, isTrue);
      expect(images.single.copies.map((c) => c.instanceId), ['a', 'b']);
    });

    test('registration order decides the primary, not arrival order', () {
      final images = mergeImages(
        [
          ref('b', 'img-b', shareId: 'share-1'),
          ref('a', 'img-a', shareId: 'share-1'),
        ],
        instanceOrder: ['a', 'b'],
      );

      expect(images.single.primary.instanceId, 'a');
    });

    test('an image with no share id is only ever itself', () {
      final images = mergeImages(
        [ref('a', 'img-1'), ref('b', 'img-1')],
        instanceOrder: ['a', 'b'],
      );

      expect(images, hasLength(2));
      expect(images.every((p) => p.isShared), isFalse);
    });

    test('the same copy arriving twice is not a second copy', () {
      final images = mergeImages(
        [
          ref('a', 'img-a', shareId: 'share-1'),
          ref('a', 'img-a', shareId: 'share-1'),
        ],
        instanceOrder: ['a'],
      );

      expect(images.single.copies, hasLength(1));
    });

    test('a second image on an instance already held does not join the image',
        () {
      final images = mergeImages(
        [
          ref('a', 'mine', shareId: 'share-1'),
          ref('a', 'theirs', shareId: 'share-1'),
        ],
        instanceOrder: ['a'],
      );

      expect(images, hasLength(2));
      expect(images.first.copies.single.id, 'mine');
      expect(images.first.isShared, isFalse);
    });

    test('the refused copy is shown separately rather than dropped', () {
      final images = mergeImages(
        [
          ref('a', 'mine', shareId: 'share-1'),
          ref('a', 'theirs', shareId: 'share-1'),
        ],
        instanceOrder: ['a'],
      );

      expect(images.last.copies.single.id, 'theirs');
      expect(images.last.identity, 'a/theirs');
    });

    test('a genuine third copy still merges alongside a refused one', () {
      final images = mergeImages(
        [
          ref('a', 'mine', shareId: 'share-1'),
          ref('a', 'theirs', shareId: 'share-1'),
          ref('b', 'mine-b', shareId: 'share-1'),
        ],
        instanceOrder: ['a', 'b'],
      );

      expect(images, hasLength(2));
      expect(images.first.copies.map((c) => c.instanceId), ['a', 'b']);
      expect(images.last.copies.single.id, 'theirs');
    });
  });

  group('SharedImage', () {
    test('uploadedAt is the earliest any copy claims', () {
      final image = SharedImage([
        ref('a', 'img-a',
            shareId: 'share-1', uploadedAt: DateTime.utc(2026, 7, 29, 12)),
        ref('b', 'img-b',
            shareId: 'share-1', uploadedAt: DateTime.utc(2026, 7, 29, 11)),
      ]);

      expect(image.uploadedAt, DateTime.utc(2026, 7, 29, 11));
    });

    test('copyOn finds the copy for an instance, or nothing', () {
      final image = SharedImage([ref('a', 'img-a', shareId: 'share-1')]);

      expect(image.copyOn('a')?.id, 'img-a');
      expect(image.copyOn('b'), isNull);
    });
  });

  group('sortImagesNewestFirst', () {
    test('orders newest first and breaks ties stably on identity', () {
      final older = SharedImage(
          [ref('a', 'old', uploadedAt: DateTime.utc(2026, 7, 1))]);
      final newer = SharedImage(
          [ref('a', 'new', uploadedAt: DateTime.utc(2026, 7, 29))]);
      final undated = SharedImage([ref('a', 'undated')]);

      final images = [older, undated, newer];
      sortImagesNewestFirst(images);

      expect(images.map((p) => p.primary.id), ['new', 'old', 'undated']);
    });
  });
}
