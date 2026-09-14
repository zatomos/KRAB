import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/cache/seen_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

CommentThread _thread(String groupId, int count, DateTime? latestAt,
        {String instanceId = 'inst_1'}) =>
    (
      instanceId: instanceId,
      groupId: groupId,
      count: count,
      latestAt: latestAt
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const identity = 'image-1';
  final trackingSince = DateTime.utc(2026, 9, 14, 9);
  final earlier = DateTime.utc(2026, 9, 14, 10);
  final later = DateTime.utc(2026, 9, 14, 12);

  late SeenState seen;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    seen = SeenState.instance..resetForTest(trackingSince: trackingSince);
  });

  group('reading every thread settles the cross-group tally', () {
    test('one group read clears the all-groups badge', () {
      final threads = [_thread('group-1', 3, later)];
      seen.markCommentsSeen('inst_1', 'group-1', identity, 3, latestAt: later);

      seen.markAllCommentsSeenIfCaughtUp(identity, threads);

      expect(
        seen.hasNewCommentsAnywhere(identity, 3, latestAt: later),
        isFalse,
        reason: 'the comments were read, so neither view should badge',
      );
    });

    test('an unread thread in another group keeps the badge', () {
      final threads = [
        _thread('group-1', 3, earlier),
        _thread('group-2', 1, later),
      ];
      seen.markCommentsSeen('inst_1', 'group-1', identity, 3,
          latestAt: earlier);

      seen.markAllCommentsSeenIfCaughtUp(identity, threads);

      expect(
        seen.hasNewCommentsAnywhere(identity, 4, latestAt: later),
        isTrue,
        reason: 'group-2 has never been opened',
      );
    });

    test('reading the last outstanding thread then clears it', () {
      final threads = [
        _thread('group-1', 3, earlier),
        _thread('group-2', 1, later),
      ];
      seen.markCommentsSeen('inst_1', 'group-1', identity, 3,
          latestAt: earlier);
      seen.markAllCommentsSeenIfCaughtUp(identity, threads);

      seen.markCommentsSeen('inst_1', 'group-2', identity, 1, latestAt: later);
      seen.markAllCommentsSeenIfCaughtUp(identity, threads);

      expect(
          seen.hasNewCommentsAnywhere(identity, 4, latestAt: later), isFalse);
    });

    test('groups on different servers are counted apart', () {
      final threads = [
        _thread('group-1', 2, earlier),
        _thread('group-1', 2, later, instanceId: 'inst_2'),
      ];
      seen.markCommentsSeen('inst_1', 'group-1', identity, 2,
          latestAt: earlier);

      seen.markAllCommentsSeenIfCaughtUp(identity, threads);

      expect(
        seen.hasNewCommentsAnywhere(identity, 4, latestAt: later),
        isTrue,
        reason: 'the same group id on another server is a different thread',
      );
    });

    test('the per-group badge is left alone', () {
      final threads = [
        _thread('group-1', 3, earlier),
        _thread('group-2', 1, later),
      ];
      seen.markCommentsSeen('inst_1', 'group-1', identity, 3,
          latestAt: earlier);

      seen.markAllCommentsSeenIfCaughtUp(identity, threads);

      expect(
        seen.hasNewComments('inst_1', 'group-2', identity, 1, latestAt: later),
        isTrue,
      );
    });
  });
}
