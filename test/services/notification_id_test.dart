import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/shown_image_notifications.dart';

void main() {
  const image = '11111111-1111-1111-1111-111111111111';
  const other = '22222222-2222-2222-2222-222222222222';

  group('imageBatchKey', () {
    test('does not depend on the order the groups arrive in', () {
      expect(imageBatchKey(['b', 'a', 'c']), imageBatchKey(['c', 'b', 'a']));
    });

    test('tells different sets of groups apart', () {
      expect(imageBatchKey(['a', 'b']), isNot(imageBatchKey(['a'])));
    });
  });

  group('imageNotificationId', () {
    test('is stable for the same photo and the same delivery', () {
      expect(
        imageNotificationId(image, batchKey: imageBatchKey(['a', 'b'])),
        imageNotificationId(image, batchKey: imageBatchKey(['b', 'a'])),
      );
    });

    test(
        'a later delivery of the same photo gets its own id, so the two '
        'notifications coexist instead of replacing each other', () {
      final firstSend =
          imageNotificationId(image, batchKey: imageBatchKey(['a', 'b']));
      final addedLater =
          imageNotificationId(image, batchKey: imageBatchKey(['d']));
      expect(firstSend, isNot(addedLater));
    });

    test('different photos delivered to the same groups stay distinct', () {
      final key = imageBatchKey(['a']);
      expect(imageNotificationId(image, batchKey: key),
          isNot(imageNotificationId(other, batchKey: key)));
    });

    test('no batch key reproduces the id an older build used', () {
      // cancelImageNotification relies on this to dismiss a notification that
      // was posted before the app was updated.
      expect(
          imageNotificationId(image, batchKey: ''), imageNotificationId(image));
    });

    test('is a valid Android notification id', () {
      final id =
          imageNotificationId(image, batchKey: imageBatchKey(['a', 'b']));
      expect(id, greaterThanOrEqualTo(0));
      expect(id, lessThanOrEqualTo(0x7FFFFFFF));
    });
  });

  group('commentThreadNotificationId', () {
    const family = 'g-family';
    const work = 'g-work';

    test('every comment on one photo in one group lands on one notification',
        () {
      expect(
        commentThreadNotificationId(groupId: family, imageId: image),
        commentThreadNotificationId(groupId: family, imageId: image),
      );
    });

    test('the same photo in two groups keeps a thread each', () {
      // A tap opens the comments of the group the comment was written in, so the
      // two cannot share a notification.
      expect(
        commentThreadNotificationId(groupId: family, imageId: image),
        isNot(commentThreadNotificationId(groupId: work, imageId: image)),
      );
    });

    test('two photos in one group stay apart', () {
      expect(
        commentThreadNotificationId(groupId: family, imageId: image),
        isNot(commentThreadNotificationId(groupId: family, imageId: other)),
      );
    });

    test('is a valid Android notification id', () {
      final id = commentThreadNotificationId(groupId: family, imageId: image);
      expect(id, greaterThanOrEqualTo(0));
      expect(id, lessThanOrEqualTo(0x7FFFFFFF));
    });
  });

  group('reactionNotificationId', () {
    test('everyone reacting to one photo lands on one notification', () {
      expect(reactionNotificationId(image), reactionNotificationId(image));
    });

    test('tells two photos apart', () {
      expect(
          reactionNotificationId(image), isNot(reactionNotificationId(other)));
    });
  });

  test('a comment and a reaction never collide with the photo itself', () {
    final ids = {
      imageNotificationId(image),
      commentThreadNotificationId(groupId: image, imageId: image),
      reactionNotificationId(image),
    };
    expect(ids, hasLength(3));
  });

  group('bundles', () {
    test('one server bundles apart from another', () {
      expect(imageBundleKey('inst_1'), isNot(imageBundleKey('inst_2')));
    });

    test('images gather whichever group they arrived in', () {
      // A bundle per group left every one of them heading a single
      // notification, since two photos rarely land in the same group.
      expect(imageBundleKey('inst_1'), imageBundleKey('inst_1'));
    });

    test('the three kinds bundle apart', () {
      // Android only draws a bundle when its summary and children share a
      // channel, and these are on three.
      expect(
        {
          imageBundleKey('inst_1'),
          commentBundleKey('inst_1'),
          reactionBundleKey('inst_1'),
        },
        hasLength(3),
      );
    });

    test('a summary never collides with a notification under it', () {
      final bundle = imageBundleKey('inst_1');
      expect(
        bundleSummaryId(bundle),
        isNot(imageNotificationId(image, batchKey: imageBatchKey(['g']))),
      );
    });
  });

  group('unidentifiedNotificationId', () {
    test('a second unidentified event of a kind replaces the first', () {
      expect(unidentifiedNotificationId('comment'),
          unidentifiedNotificationId('comment'));
    });

    test('two kinds do not overwrite each other', () {
      expect(unidentifiedNotificationId('comment'),
          isNot(unidentifiedNotificationId('reaction')));
    });
  });

  group('image copies on several servers', () {
    const shared = '99999999-9999-9999-9999-999999999999';

    test('every server\'s copy lands on one notification', () {
      final fromOne = imageNotificationId(image,
          batchKey: imageBatchKey(['a', 'b']), shareId: shared);
      final fromTwo = imageNotificationId(other,
          batchKey: imageBatchKey(['c']), shareId: shared);

      expect(fromOne, fromTwo);
    });

    test('an empty share id counts as none, not as one everything shares', () {
      expect(
        imageNotificationId(image, batchKey: imageBatchKey(['a']), shareId: ''),
        imageNotificationId(image, batchKey: imageBatchKey(['a'])),
      );
      expect(
        imageNotificationId(image, shareId: ''),
        isNot(imageNotificationId(other, shareId: '')),
      );
    });

    test('two different photos keep their own notifications', () {
      expect(imageNotificationId(image, shareId: shared),
          isNot(imageNotificationId(other, shareId: 'other-share')));
    });
  });

  group('mergeGroupsDisplay', () {
    test('keeps the groups the notification on screen already named', () {
      expect(mergeGroupsDisplay('Family', 'Work'), 'Family, Work');
    });

    test('does not repeat a group both servers know about', () {
      expect(mergeGroupsDisplay('Family, Work', 'Work'), 'Family, Work');
    });

    test('survives an empty side', () {
      expect(mergeGroupsDisplay('', 'Work'), 'Work');
      expect(mergeGroupsDisplay('Family', ''), 'Family');
    });
  });

  group('mergeImageNotification', () {
    ShownImageNotification shown({
      required String groups,
      required String ids,
      String tapGroupId = '',
    }) =>
        ShownImageNotification(
          groupsDisplay: groups,
          imageIds: ids,
          tapGroupId: tapGroupId,
          shownAt: DateTime.now(),
        );

    test('the first delivery speaks for itself', () {
      final merged = mergeImageNotification(
        earlier: null,
        arrivingGroups: 'Family',
        arrivingImageId: image,
        tapGroupId: 'g-family',
      );

      expect(merged.groupsDisplay, 'Family');
      expect(merged.imageIds, image);
      expect(merged.tapGroupId, 'g-family',
          reason: 'one group, one gallery to open');
    });

    test('another server\'s copy adds its groups and loses the tap target', () {
      final merged = mergeImageNotification(
        earlier: shown(groups: 'Family', ids: image, tapGroupId: 'g-family'),
        arrivingGroups: 'Work',
        arrivingImageId: other,
        tapGroupId: 'g-work',
      );

      expect(merged.groupsDisplay, 'Family, Work');
      expect(merged.imageIds, '$image,$other');
      expect(merged.tapGroupId, isNull,
          reason: 'no single gallery holds both groups, so the tap opens the '
              'cross-group feed');
    });

    test('a second batch of groups on the same server merges too', () {
      // Same copy of the photo, a later send to another group on that server.
      final merged = mergeImageNotification(
        earlier: shown(groups: 'Family', ids: image, tapGroupId: 'g-family'),
        arrivingGroups: 'Friends',
        arrivingImageId: image,
        tapGroupId: 'g-friends',
      );

      expect(merged.groupsDisplay, 'Family, Friends');
      expect(merged.imageIds, image);
      expect(merged.tapGroupId, isNull);
    });

    test('the same delivery arriving twice changes nothing', () {
      final merged = mergeImageNotification(
        earlier: shown(groups: 'Family', ids: image, tapGroupId: 'g-family'),
        arrivingGroups: 'Family',
        arrivingImageId: image,
        tapGroupId: 'g-family',
      );

      expect(merged.groupsDisplay, 'Family');
      expect(merged.imageIds, image);
      expect(merged.tapGroupId, 'g-family',
          reason: 'a redelivery must not talk the notification out of its '
              'gallery');
    });

    test('a notification already opening the feed keeps doing so', () {
      final merged = mergeImageNotification(
        earlier: shown(groups: 'Family, Work', ids: '$image,$other'),
        arrivingGroups: 'Family',
        arrivingImageId: image,
        tapGroupId: 'g-family',
      );

      expect(merged.groupsDisplay, 'Family, Work');
      expect(merged.tapGroupId, isNull);
    });
  });

  group('mergeCoveredImageIds', () {
    test('keeps the copy already recorded', () {
      expect(mergeCoveredImageIds(image, other), '$image,$other');
    });

    test('does not record a copy twice', () {
      expect(mergeCoveredImageIds('$image,$other', image), '$image,$other');
    });

    test('survives an empty side', () {
      expect(mergeCoveredImageIds('', image), image);
    });
  });
}
