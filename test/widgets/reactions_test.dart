import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/reaction.dart';
import 'package:krab/widgets/reactions_bar.dart';
import 'package:krab/widgets/reactors_sheet.dart';

void main() {
  group('applyToggle', () {
    // The bar applies the toggle optimistically, before the server confirms, so
    // this is what the user actually sees when they tap an emoji.
    test('adds an emoji nobody has used', () {
      final result = ReactionsBarState.applyToggle(const [], '👍');

      expect(result, hasLength(1));
      expect(result.single.emoji, '👍');
      expect(result.single.count, 1);
      expect(result.single.reactedByMe, isTrue);
    });

    test('joins a reaction someone else already made', () {
      final result = ReactionsBarState.applyToggle(
        const [ReactionSummary(emoji: '👍', count: 3, reactedByMe: false)],
        '👍',
      );

      expect(result.single.count, 4);
      expect(result.single.reactedByMe, isTrue);
    });

    test('taking back my reaction leaves the others', () {
      final result = ReactionsBarState.applyToggle(
        const [ReactionSummary(emoji: '👍', count: 3, reactedByMe: true)],
        '👍',
      );

      expect(result.single.count, 2);
      expect(result.single.reactedByMe, isFalse);
    });

    test('taking back the only reaction drops the chip entirely', () {
      final result = ReactionsBarState.applyToggle(
        const [ReactionSummary(emoji: '👍', count: 1, reactedByMe: true)],
        '👍',
      );

      expect(result, isEmpty, reason: 'a zero-count chip should not linger');
    });

    test('leaves the other emojis alone', () {
      final result = ReactionsBarState.applyToggle(
        const [
          ReactionSummary(emoji: '👍', count: 2, reactedByMe: false),
          ReactionSummary(emoji: '🔥', count: 1, reactedByMe: true),
        ],
        '👍',
      );

      expect(result, hasLength(2));
      expect(result.firstWhere((r) => r.emoji == '🔥').count, 1);
      expect(result.firstWhere((r) => r.emoji == '👍').count, 3);
    });
  });

  group('visibleChipsFor', () {
    // The bar used to show a fixed 4 chips whatever the screen. Now it fits as
    // many as there is room for.
    int fit(double width, int count) =>
        ReactionsBarState.visibleChipsFor(width, count);

    test('nothing to show when there are no reactions', () {
      expect(fit(400, 0), 0);
    });

    test('shows them all when they fit', () {
      expect(fit(400, 2), 2, reason: '2 chips easily fit a 400px bar');
    });

    test('a wider screen shows more than a narrow one', () {
      expect(fit(720, 8), greaterThan(fit(360, 8)));
    });

    test('never shows more chips than there are reactions', () {
      expect(fit(2000, 3), 3);
    });

    test('leaves at least one visible on an absurdly narrow screen', () {
      expect(fit(60, 5), 1);
    });

    test('gives up a slot to the "+N" chip once it has to hide some', () {
      const width = 460.0;

      // The most reactions this width can show with no "+N" chip: the largest n
      // where asking for n gives back all n.
      var allFit = 1;
      for (var n = 1; n <= 20; n++) {
        if (fit(width, n) == n) allFit = n;
      }
      expect(allFit, greaterThan(1), reason: 'need room for the test to mean something');

      // One more reaction than that, and the "+N" chip has to be paid for out of
      // the same width, so fewer reactions get shown than the bar could hold.
      final shown = fit(width, allFit + 1);
      expect(shown, lessThan(allFit),
          reason: 'the +N chip must cost a reaction slot');
      expect(allFit + 1 - shown, greaterThan(0),
          reason: 'something must actually be hidden behind the +N');
    });
  });

  group('groupReactors', () {
    const reactors = [
      Reactor(emoji: '👍', userId: 'u1', username: 'ana'),
      Reactor(emoji: '🔥', userId: 'u2', username: 'bo'),
      Reactor(emoji: '🔥', userId: 'u1', username: 'ana'),
    ];

    test('gives each person one row carrying all their emojis', () {
      final rows = groupReactors(reactors);

      expect(rows, hasLength(2));
      expect(rows.first.userId, 'u1');
      expect(rows.first.emojis, ['👍', '🔥']);
      expect(rows.last.emojis, ['🔥']);
    });

    test('keeps the order people first appear in', () {
      // ana reacted first, so she leads, even though bo's row is finished first.
      expect(groupReactors(reactors).map((r) => r.username), ['ana', 'bo']);
    });

    test('filters to a single emoji', () {
      final rows = groupReactors(reactors, emoji: '🔥');

      expect(rows.map((r) => r.username), ['bo', 'ana']);
      expect(rows.every((r) => r.emojis == const ['🔥']), isFalse);
      expect(rows.first.emojis, ['🔥']);
    });

    test('no reactions means no rows', () {
      expect(groupReactors(const []), isEmpty);
    });
  });

  group('emojisByUse', () {
    test('orders the tabs by how many people used each emoji', () {
      final emojis = emojisByUse(const [
        Reactor(emoji: '👍', userId: 'u1', username: 'a'),
        Reactor(emoji: '🔥', userId: 'u2', username: 'b'),
        Reactor(emoji: '🔥', userId: 'u3', username: 'c'),
      ]);

      expect(emojis, ['🔥', '👍']);
    });

    test('breaks ties alphabetically, so the tabs do not shuffle', () {
      final once = emojisByUse(const [
        Reactor(emoji: 'b', userId: 'u1', username: 'x'),
        Reactor(emoji: 'a', userId: 'u2', username: 'y'),
      ]);

      expect(once, ['a', 'b']);
    });
  });
}
