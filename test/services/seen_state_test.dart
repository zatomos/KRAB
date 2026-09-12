import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/services/cache/seen_state.dart';

void main() {
  const inst = 'inst_1';
  const family = 'g-family';
  const work = 'g-work';
  const imageA = 'image-a';
  const imageB = 'image-b';

  final seen = SeenState.instance;
  final now = DateTime.now();
  final yesterday = now.subtract(const Duration(days: 1));
  final lastHour = now.subtract(const Duration(hours: 1));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    seen.resetForTest(trackingSince: now.subtract(const Duration(days: 7)));
  });

  group('images', () {
    test('an image not opened yet is new', () {
      expect(seen.isImageNew(imageA, lastHour), isTrue);
    });

    test('opening one image says nothing about another', () {
      seen.markImageSeen(imageB, lastHour);

      expect(seen.isImageNew(imageB, lastHour), isFalse);
      expect(seen.isImageNew(imageA, yesterday), isTrue);
    });

    test('an image from before counting began is not news', () {
      seen.resetForTest(trackingSince: now.subtract(const Duration(hours: 2)));

      expect(seen.isImageNew(imageA, now.subtract(const Duration(days: 3))),
          isFalse);
      expect(seen.isImageNew(imageA, lastHour), isTrue);
    });

    test('history from before counting began is never new', () {
      seen.resetForTest(trackingSince: now.subtract(const Duration(days: 1)));

      expect(seen.isImageNew(imageA, now.subtract(const Duration(days: 400))),
          isFalse);
    });

    test('an image with no upload time is not guessed at', () {
      expect(seen.isImageNew(imageA, null), isFalse);
    });

    test('one image on two servers is one image', () {
      seen.markImageSeen('share-1', lastHour);

      expect(seen.isImageNew('share-1', lastHour), isFalse);
    });

    test('the count is what the groups page shows', () {
      seen.markImageSeen(imageB, lastHour);

      final count = seen.newImageCount([
        (identity: imageA, uploadedAt: lastHour),
        (identity: imageB, uploadedAt: lastHour),
        (identity: 'image-c', uploadedAt: lastHour),
      ]);

      expect(count, 2);
    });
  });

  group('comments', () {
    test('comments never read are all unread', () {
      expect(seen.hasNewComments(inst, family, imageA, 3), isTrue);
    });

    test('comments written before counting began are not unread', () {
      expect(
          seen.hasNewComments(inst, family, imageA, 3,
              latestAt: now.subtract(const Duration(days: 30))),
          isFalse);
      expect(seen.hasNewComments(inst, family, imageA, 3, latestAt: lastHour),
          isTrue);
    });

    test('a comment replaced by another is still news', () {
      final read = now.subtract(const Duration(minutes: 30));
      seen.markCommentsSeen(inst, family, imageA, 3, latestAt: read);

      expect(seen.hasNewComments(inst, family, imageA, 3, latestAt: read),
          isFalse);
      expect(
          seen.hasNewComments(inst, family, imageA, 3,
              latestAt: now.subtract(const Duration(minutes: 1))),
          isTrue);
    });

    test('asking does not quietly mark them read', () {
      seen.hasNewComments(inst, family, imageA, 3);

      expect(seen.hasNewComments(inst, family, imageA, 3), isTrue);
    });

    test('an image with no comments has none unread', () {
      expect(seen.hasNewComments(inst, family, imageA, 0), isFalse);
    });

    test('a comment arriving after that is new', () {
      seen.markCommentsSeen(inst, family, imageA, 3);

      expect(seen.hasNewComments(inst, family, imageA, 4), isTrue);
    });

    test('opening the thread clears it', () {
      seen.markCommentsSeen(inst, family, imageA, 3);
      expect(seen.hasNewComments(inst, family, imageA, 4), isTrue);

      seen.markCommentsSeen(inst, family, imageA, 4);
      expect(seen.hasNewComments(inst, family, imageA, 4), isFalse);
    });

    test('each group is counted on its own', () {
      // The image is in both groups; reading it in one leaves the other.
      seen.markCommentsSeen(inst, family, imageA, 1);
      seen.markCommentsSeen(inst, work, imageA, 1);

      seen.markCommentsSeen(inst, family, imageA, 2);

      expect(seen.hasNewComments(inst, family, imageA, 2), isFalse);
      expect(seen.hasNewComments(inst, work, imageA, 2), isTrue);
    });

    test('a group gallery and the cross-group feed count differently', () {
      seen.markCommentsSeen(inst, family, imageA, 2);
      seen.markAllCommentsSeen(imageA, 5);

      // The group is up to date, the total is not.
      expect(seen.hasNewComments(inst, family, imageA, 2), isFalse);
      expect(seen.hasNewCommentsAnywhere(imageA, 6), isTrue);

      // And a total of 5 does not make the group of 2 look unread.
      expect(seen.hasNewCommentsAnywhere(imageA, 5), isFalse);
      expect(seen.hasNewComments(inst, family, imageA, 2), isFalse);
    });

    test('reading every group clears the total on its own', () {
      seen.markAllCommentsSeen(imageA, 4);

      expect(seen.hasNewCommentsAnywhere(imageA, 4), isFalse);
      expect(seen.hasNewCommentsAnywhere(imageA, 5), isTrue);
    });

    test('a comment deleted since does not go negative', () {
      seen.markCommentsSeen(inst, family, imageA, 5);

      expect(seen.hasNewComments(inst, family, imageA, 4), isFalse);
    });
  });

  group('reactions', () {
    test('reactions on an image that arrived since are unread', () {
      expect(seen.hasNewReactions(imageA, {'love': 2}, uploadedAt: lastHour),
          isTrue);
      expect(seen.hasNewReactions(imageA, const {}, uploadedAt: lastHour),
          isFalse);
    });

    test('reactions already there when counting began are not', () {
      seen.resetForTest(trackingSince: now.subtract(const Duration(hours: 2)));

      expect(
          seen.hasNewReactions(imageA, {'love': 2},
              uploadedAt: now.subtract(const Duration(days: 3))),
          isFalse);
    });

    test('a reaction arriving after that is new, and opening clears it', () {
      seen.markReactionsSeen(imageA, {'love': 2});
      expect(seen.hasNewReactions(imageA, {'love': 3}), isTrue);

      seen.markReactionsSeen(imageA, {'love': 3});
      expect(seen.hasNewReactions(imageA, {'love': 3}), isFalse);
    });

    test('one reaction swapped for another is news, though the count is not',
        () {
      seen.markReactionsSeen(imageA, {'thumbs': 1});

      expect(seen.hasNewReactions(imageA, {'heart': 1}), isTrue);
    });

    test('a reaction taken away is not news', () {
      seen.markReactionsSeen(imageA, {'love': 2, 'thumbs': 1});

      expect(seen.hasNewReactions(imageA, {'love': 2}), isFalse);
      expect(seen.hasNewReactions(imageA, {'love': 1}), isFalse);
    });

    test('a new emoji among ones already seen is news', () {
      seen.markReactionsSeen(imageA, {'love': 2});

      expect(seen.hasNewReactions(imageA, {'love': 2, 'heart': 1}), isTrue);
    });

    test('reactions are not split by group, comments are', () {
      seen.markReactionsSeen(imageA, {'love': 1});
      seen.markCommentsSeen(inst, family, imageA, 1);

      expect(seen.hasNewReactions(imageA, {'love': 1}), isFalse);
      expect(seen.hasNewComments(inst, family, imageA, 1), isFalse);
      expect(seen.hasNewComments(inst, work, imageA, 1), isTrue);
    });
  });

  group('storage', () {
    test('what was seen survives a reload', () async {
      seen.markImageSeen(imageA, lastHour);
      seen.markCommentsSeen(inst, family, imageA, 2);
      seen.markReactionsSeen(imageA, {'love': 1});
      await seen.flush();

      seen.resetForTest();
      await seen.load();

      expect(seen.isImageNew(imageA, lastHour), isFalse);
      expect(seen.hasNewComments(inst, family, imageA, 2), isFalse,
          reason: 'the baseline came back with it');
      expect(seen.hasNewComments(inst, family, imageA, 3), isTrue);
      expect(seen.hasNewReactions(imageA, {'love': 1}), isFalse,
          reason: 'the tally came back with it');
      expect(seen.hasNewReactions(imageA, {'love': 2}), isTrue);
    });

    test('a first run starts counting from now, so nothing is unread',
        () async {
      seen.resetForTest();
      await seen.load();

      expect(seen.isImageNew(imageA, yesterday), isFalse);
    });

    test('unreadable storage starts over rather than throwing', () async {
      SharedPreferences.setMockInitialValues({SeenState.prefsKey: 'not json'});
      seen.resetForTest();

      await seen.load();

      expect(seen.isImageNew(imageA, yesterday), isFalse);
    });

    test('images from before counting began are dropped', () async {
      seen.resetForTest(trackingSince: now.subtract(const Duration(hours: 1)));
      seen.markImageSeen(imageA, now.subtract(const Duration(days: 2)));
      seen.markImageSeen(imageB, now);

      seen.prune();
      await seen.flush();
      final stored = (await SharedPreferences.getInstance())
          .getString(SeenState.prefsKey)!;

      expect(stored, isNot(contains(imageA)));
      expect(stored, contains(imageB));
    });

    test('the store stays bounded, and what it drops cannot come back', () {
      seen.resetForTest(trackingSince: now.subtract(const Duration(days: 400)));
      for (var i = 0; i < 1200; i++) {
        seen.markImageSeen(
            'image-$i', now.subtract(Duration(minutes: 1200 - i)));
      }

      seen.prune();

      expect(seen.storedImageCount, lessThanOrEqualTo(1000));
      expect(
          seen.isImageNew(
              'image-0', now.subtract(const Duration(minutes: 1200))),
          isFalse);
      expect(
          seen.isImageNew(
              'image-1199', now.subtract(const Duration(minutes: 1))),
          isFalse);
    });

    test('clearing forgets everything', () async {
      seen.markImageSeen(imageA, lastHour);

      await seen.clear();

      expect(seen.isImageNew(imageA, lastHour), isFalse,
          reason: 'counting restarts, so nothing before now is unread');
    });
  });
}
