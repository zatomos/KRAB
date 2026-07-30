import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/services/shown_image_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const image = '11111111-1111-1111-1111-111111111111';
  const other = '22222222-2222-2222-2222-222222222222';

  final store = ShownImageNotifications.instance;

  ShownImageNotification entry({
    String groups = 'Family',
    String ids = image,
    String tapGroupId = '',
    Duration age = Duration.zero,
  }) =>
      ShownImageNotification(
        groupsDisplay: groups,
        imageIds: ids,
        tapGroupId: tapGroupId,
        shownAt: DateTime.now().subtract(age),
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('what was recorded is what comes back', () async {
    await store.record(7, entry(groups: 'Family, Work', tapGroupId: 'g1'));

    final read = await store.read(7);

    expect(read?.groupsDisplay, 'Family, Work');
    expect(read?.imageIds, image);
    expect(read?.tapGroupId, 'g1');
  });

  test('nothing is recorded for a notification never shown', () async {
    expect(await store.read(7), isNull);
  });

  test('recording again replaces what the notification said', () async {
    await store.record(7, entry(groups: 'Family'));
    await store.record(7, entry(groups: 'Family, Work', ids: '$image,$other'));

    final read = await store.read(7);

    expect(read?.groupsDisplay, 'Family, Work');
    expect(read?.imageIds, '$image,$other');
  });

  test('two notifications are kept apart', () async {
    await store.record(7, entry(groups: 'Family'));
    await store.record(8, entry(groups: 'Work', ids: other));

    expect((await store.read(7))?.groupsDisplay, 'Family');
    expect((await store.read(8))?.groupsDisplay, 'Work');
  });

  test('a record too old to be on screen is not offered', () async {
    await store.record(7,
        entry(age: ShownImageNotifications.maxAge + const Duration(hours: 1)));

    expect(await store.read(7), isNull,
        reason: 'merging into it would name groups from a photo long gone');
  });

  test('a forgotten notification stops being merged into', () async {
    await store.record(7, entry());
    await store.forget([7]);

    expect(await store.read(7), isNull);
  });

  group('idsCovering', () {
    test('finds the notification another copy started and merged', () async {
      // The notification hangs off the share id, so a copy that arrived second
      // cannot derive the id it ended up on.
      await store.record(
          7, entry(groups: 'Family, Work', ids: '$image,$other'));

      expect(await store.idsCovering(other), [7]);
    });

    test('leaves a notification about another photo alone', () async {
      await store.record(7, entry(ids: image));

      expect(await store.idsCovering(other), isEmpty);
    });

    test('an empty image id covers nothing', () async {
      await store.record(7, entry(ids: image));

      expect(await store.idsCovering(''), isEmpty);
    });
  });

  test('unreadable storage is treated as nothing recorded', () async {
    SharedPreferences.setMockInitialValues(
        {ShownImageNotifications.prefsKey: 'not json'});

    expect(await store.read(7), isNull);
  });

  test('the record survives a write from another isolate', () async {
    // Two isolates, one store: the second isolate's prefs are seeded behind this
    // one's back, the way a background push handler's write looks from here.
    await store.record(7, entry(groups: 'Family'));
    SharedPreferences.setMockInitialValues({
      ShownImageNotifications.prefsKey: jsonEncode({
        '7': {
          'groups_display': 'Family, Work',
          'image_ids': '$image,$other',
          'tap_group_id': '',
          'shown_at': DateTime.now().toIso8601String(),
        }
      })
    });

    expect((await store.read(7))?.groupsDisplay, 'Family, Work');
  });

  test('serialized bodies do not interleave', () async {
    // What the merge relies on: read-then-record for one photo completes before
    // the next copy of it starts reading.
    final order = <String>[];

    Future<void> body(String name) => store.serialized(() async {
          order.add('$name-start');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          order.add('$name-end');
        });

    await Future.wait([body('first'), body('second')]);

    expect(order, ['first-start', 'first-end', 'second-start', 'second-end']);
  });

  test('a failure in one serialized body does not stall the queue', () async {
    await expectLater(
      store.serialized(() async => throw StateError('boom')),
      throwsStateError,
    );

    expect(await store.serialized(() async => 'ran'), 'ran');
  });
}
