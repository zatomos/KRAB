import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/notification_channels.dart';

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

    test('a later delivery of the same photo gets its own id, so the two '
        'notifications coexist instead of replacing each other', () {
      final firstSend = imageNotificationId(image, batchKey: imageBatchKey(['a', 'b']));
      final addedLater = imageNotificationId(image, batchKey: imageBatchKey(['d']));
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
      expect(imageNotificationId(image, batchKey: ''), imageNotificationId(image));
    });

    test('is a valid Android notification id', () {
      final id = imageNotificationId(image, batchKey: imageBatchKey(['a', 'b']));
      expect(id, greaterThanOrEqualTo(0));
      expect(id, lessThanOrEqualTo(0x7FFFFFFF));
    });
  });

  group('commentNotificationId', () {
    const comment = '33333333-3333-3333-3333-333333333333';

    test('is stable for the same comment', () {
      expect(commentNotificationId(comment), commentNotificationId(comment));
    });

    test('tells two comments apart', () {
      expect(commentNotificationId(comment),
          isNot(commentNotificationId('44444444-4444-4444-4444-444444444444')));
    });

    test('is a valid Android notification id', () {
      final id = commentNotificationId(comment);
      expect(id, greaterThanOrEqualTo(0));
      expect(id, lessThanOrEqualTo(0x7FFFFFFF));
    });
  });

  group('reactionNotificationId', () {
    const reactor = '55555555-5555-5555-5555-555555555555';

    test('is stable for one user reacting to one photo', () {
      expect(reactionNotificationId(image, reactor),
          reactionNotificationId(image, reactor));
    });

    test('tells two reactors on the same photo apart', () {
      expect(reactionNotificationId(image, reactor),
          isNot(reactionNotificationId(image, 'someone-else')));
    });

    test('tells the same reactor on two photos apart', () {
      expect(reactionNotificationId(image, reactor),
          isNot(reactionNotificationId(other, reactor)));
    });
  });

  test('a comment and a reaction never collide with the photo itself', () {
    final ids = {
      imageNotificationId(image),
      commentNotificationId(image),
      reactionNotificationId(image, image),
    };
    expect(ids, hasLength(3));
  });
}
