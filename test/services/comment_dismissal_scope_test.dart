import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/notification_records.dart';

void main() {
  const image = '11111111-1111-1111-1111-111111111111';
  const other = '22222222-2222-2222-2222-222222222222';
  final store = CommentThreads.instance;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  CommentThread threadIn(String groupId, {String imageId = image}) =>
      CommentThread(
        instanceId: 'inst_1',
        groupId: groupId,
        groupName: groupId,
        imageId: imageId,
        messages: const [],
        shownAt: DateTime.now(),
      );

  int idFor(String groupId, {String imageId = image}) =>
      commentThreadNotificationId(groupId: groupId, imageId: imageId);

  Future<void> record(String groupId, {String imageId = image}) =>
      store.record(idFor(groupId, imageId: imageId),
          threadIn(groupId, imageId: imageId));

  test('opened inside a group, only that group\'s thread is dismissed',
      () async {
    await record('g-family');
    await record('g-work');

    final ids =
        await commentNotificationIdsToDismiss(image, groupId: 'g-family');

    expect(ids, [idFor('g-family')]);
    expect(ids, isNot(contains(idFor('g-work'))));
  });

  test('opened from the cross-group feed, every thread about it is dismissed',
      () async {
    await record('g-family');
    await record('g-work');

    final ids = await commentNotificationIdsToDismiss(image);

    expect(ids.toSet(), {idFor('g-family'), idFor('g-work')});
  });

  test('another image\'s threads are never touched', () async {
    await record('g-family');
    await record('g-family', imageId: other);

    final ids = await commentNotificationIdsToDismiss(image);

    expect(ids, [idFor('g-family')]);
    expect(ids, isNot(contains(idFor('g-family', imageId: other))));
  });

  test('a group with nothing showing asks for its own id regardless', () async {
    final ids = await commentNotificationIdsToDismiss(image, groupId: 'g-none');

    expect(ids, [idFor('g-none')]);
  });

  test('an image with no id at all asks for nothing', () async {
    expect(await commentNotificationIdsToDismiss(''), isEmpty);
    expect(await commentNotificationIdsToDismiss('', groupId: 'g-family'),
        isEmpty);
  });
}
