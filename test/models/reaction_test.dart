import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/reaction.dart';

void main() {
  group('ReactionSummary.fromJson', () {
    test('parses a well-formed payload', () {
      final r = ReactionSummary.fromJson({
        'emoji': '🎉',
        'count': 3,
        'reacted_by_me': true,
      });

      expect(r.emoji, '🎉');
      expect(r.count, 3);
      expect(r.reactedByMe, isTrue);
    });

    test('applies safe defaults for missing fields', () {
      final r = ReactionSummary.fromJson({});
      expect(r.emoji, '');
      expect(r.count, 0);
      expect(r.reactedByMe, isFalse);
    });

    test('coerces a numeric (double) count to int', () {
      final r = ReactionSummary.fromJson({'emoji': '👍', 'count': 2.0});
      expect(r.count, 2);
    });

    test('treats any non-true reacted_by_me as false', () {
      expect(
        ReactionSummary.fromJson({'reacted_by_me': 'yes'}).reactedByMe,
        isFalse,
      );
      expect(
        ReactionSummary.fromJson({'reacted_by_me': 1}).reactedByMe,
        isFalse,
      );
    });
  });

  group('copyWith', () {
    test('keeps the emoji and overrides count/reactedByMe', () {
      final base =
          const ReactionSummary(emoji: '❤️', count: 1, reactedByMe: false);
      final updated = base.copyWith(count: 2, reactedByMe: true);

      expect(updated.emoji, '❤️');
      expect(updated.count, 2);
      expect(updated.reactedByMe, isTrue);
    });
  });
}
