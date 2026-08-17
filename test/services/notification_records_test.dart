import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/notification_records.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const image = '11111111-1111-1111-1111-111111111111';
  final now = DateTime(2026, 8, 17, 12);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  CommentThread emptyThread({
    String groupId = 'g-family',
    String uploader = 'alice',
    bool uploaderIsMe = false,
  }) =>
      CommentThread(
        instanceId: 'inst_1',
        groupId: groupId,
        groupName: 'Family',
        imageId: image,
        messages: const [],
        shownAt: now,
        uploaderUsername: uploader,
        uploaderIsMe: uploaderIsMe,
      );

  ThreadMessage message(
    String author,
    String text, {
    Duration ago = Duration.zero,
  }) =>
      ThreadMessage(
        authorId: 'u-$author',
        authorUsername: author,
        text: text,
        at: now.subtract(ago),
      );

  group('CommentThread.withMessage', () {
    test('the first comment starts the thread', () {
      final thread = emptyThread().withMessage(message('bob', 'nice one'));

      expect(thread.messages.single.text, 'nice one');
    });

    test('a second comment joins the one already showing', () {
      final thread = emptyThread()
          .withMessage(message('bob', 'first', ago: const Duration(minutes: 5)))
          .withMessage(message('carol', 'second'));

      expect(thread.messages.map((m) => m.text), ['first', 'second']);
    });

    test('comments read oldest first, however they arrive', () {
      // A device waking up can be handed the newer push first.
      final thread = emptyThread()
          .withMessage(message('carol', 'second'))
          .withMessage(
              message('bob', 'first', ago: const Duration(minutes: 5)));

      expect(thread.messages.map((m) => m.text), ['first', 'second']);
    });

    test('the same comment delivered twice is shown once', () {
      // Both copies of an image answer for it, and a push can simply arrive
      // again.
      final arriving = message('bob', 'nice one');
      final thread = emptyThread().withMessage(arriving).withMessage(arriving);

      expect(thread.messages, hasLength(1));
    });

    test('the same words from two people are two comments', () {
      final thread = emptyThread()
          .withMessage(message('bob', 'nice one'))
          .withMessage(message('carol', 'nice one'));

      expect(thread.messages, hasLength(2));
    });

    test('the same words said twice are two comments', () {
      final thread = emptyThread()
          .withMessage(
              message('bob', 'nice one', ago: const Duration(hours: 1)))
          .withMessage(message('bob', 'nice one'));

      expect(thread.messages, hasLength(2));
    });

    test('a long thread keeps the newest comments', () {
      var thread = emptyThread();
      for (var i = 0; i < CommentThread.maxMessages + 4; i++) {
        thread = thread.withMessage(message('bob', 'comment $i',
            ago: Duration(minutes: CommentThread.maxMessages + 4 - i)));
      }

      expect(thread.messages, hasLength(CommentThread.maxMessages));
      expect(thread.messages.last.text,
          'comment ${CommentThread.maxMessages + 3}');
    });

    test('who the image belongs to survives a new comment', () {
      final thread = emptyThread(uploaderIsMe: true, uploader: '')
          .withMessage(message('bob', 'nice one'));

      expect(thread.uploaderIsMe, isTrue);
      expect(thread.groupName, 'Family');
    });
  });

  group('CommentThread.participants', () {
    test('the person who just spoke comes first', () {
      final thread = emptyThread()
          .withMessage(message('bob', 'first', ago: const Duration(minutes: 5)))
          .withMessage(message('carol', 'second'));

      expect(thread.participants.map((p) => p.username), ['carol', 'bob']);
    });

    test('someone who said two things is named once', () {
      final thread = emptyThread()
          .withMessage(message('bob', 'first', ago: const Duration(minutes: 5)))
          .withMessage(message('bob', 'second'));

      expect(thread.participants, hasLength(1));
    });
  });

  group('ReactionTally.withReaction', () {
    ReactionTally emptyTally({String uploader = ''}) => ReactionTally(
          instanceId: 'inst_1',
          imageId: image,
          reactions: const [],
          shownAt: now,
          uploaderUsername: uploader,
        );

    ReactionEntry reaction(String who, String emoji,
            {Duration ago = Duration.zero}) =>
        ReactionEntry(
          reactorId: 'u-$who',
          reactorUsername: who,
          emoji: emoji,
          at: now.subtract(ago),
        );

    test('two people reacting are both counted', () {
      final tally = emptyTally()
          .withReaction(reaction('bob', '👍'))
          .withReaction(reaction('carol', '🔥'));

      expect(tally.reactions, hasLength(2));
    });

    test('changing your emoji replaces what you had', () {
      final tally = emptyTally()
          .withReaction(reaction('bob', '👍', ago: const Duration(minutes: 1)))
          .withReaction(reaction('bob', '🔥'));

      expect(tally.reactions.single.emoji, '🔥');
    });

    test('the newest reactor is the one the notification names', () {
      final tally = emptyTally()
          .withReaction(reaction('bob', '👍', ago: const Duration(minutes: 1)))
          .withReaction(reaction('carol', '🔥'));

      expect(tally.newestFirst.first.reactorUsername, 'carol');
    });

    test('a busy image keeps the newest reactors', () {
      var tally = emptyTally();
      for (var i = 0; i < ReactionTally.maxReactions + 3; i++) {
        tally = tally.withReaction(reaction('person$i', '👍'));
      }

      expect(tally.reactions, hasLength(ReactionTally.maxReactions));
      expect(tally.newestFirst.first.reactorUsername,
          'person${ReactionTally.maxReactions + 2}');
    });

    test('whose image it is survives a new reaction', () {
      final tally =
          emptyTally(uploader: 'alice').withReaction(reaction('bob', '👍'));

      expect(tally.uploaderUsername, 'alice');
    });
  });

  group('CommentThreads store', () {
    final store = CommentThreads.instance;

    test('what was recorded is what comes back', () async {
      await store.record(7, emptyThread().withMessage(message('bob', 'hi')));

      final read = await store.read(7);

      expect(read?.messages.single.text, 'hi');
      expect(read?.groupId, 'g-family');
      expect(read?.instanceId, 'inst_1');
    });

    test('a thread too old to be on screen is not offered', () async {
      final stale = CommentThread(
        instanceId: 'inst_1',
        groupId: 'g-family',
        groupName: 'Family',
        imageId: image,
        messages: const [],
        shownAt: DateTime.now()
            .subtract(CommentThreads.storeMaxAge + const Duration(hours: 1)),
      );
      await store.record(7, stale);

      expect(await store.read(7), isNull);
    });

    test('the threads about a deleted image can all be found', () async {
      await store.record(7, emptyThread(groupId: 'g-family'));
      await store.record(8, emptyThread(groupId: 'g-work'));
      await store.record(
        9,
        CommentThread(
          instanceId: 'inst_1',
          groupId: 'g-family',
          groupName: 'Family',
          imageId: '22222222-2222-2222-2222-222222222222',
          messages: const [],
          shownAt: now,
        ),
      );

      expect((await store.idsForImage(image)).toSet(), {7, 8});
    });

    test('unreadable storage is treated as nothing recorded', () async {
      SharedPreferences.setMockInitialValues(
          {CommentThreads.storeKey: 'not json'});

      expect(await store.read(7), isNull);
    });
  });

  group('isLegacyNotificationChannel', () {
    test('a per-group channel is one to remove', () {
      // Those were created with the group id as the channel id.
      expect(isLegacyNotificationChannel(image), isTrue);
    });

    test('the fixed ids that build used are too', () {
      expect(isLegacyNotificationChannel('reactions'), isTrue);
      expect(isLegacyNotificationChannel('app_updates'), isTrue);
    });

    test('the channels this build posts on are left alone', () {
      for (final channel in KrabChannel.values) {
        expect(isLegacyNotificationChannel(channel.id), isFalse,
            reason: '${channel.id} is in use');
      }
    });

    test('another plugin\'s channel is not ours to delete', () {
      expect(isLegacyNotificationChannel('fcm_fallback_notification_channel'),
          isFalse);
      expect(isLegacyNotificationChannel('krab_debug'), isFalse);
    });
  });
}
