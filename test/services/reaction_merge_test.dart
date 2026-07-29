import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/reaction.dart';
import 'package:krab/services/shared_image_api.dart';

/// One copy's tally, as that server reported it.
List<ReactionSummary> tally(List<(String, int, bool)> rows) => [
      for (final (emoji, count, mine) in rows)
        ReactionSummary(emoji: emoji, count: count, reactedByMe: mine)
    ];

void main() {
  _copySelection();

  group('mergeTallies', () {
    test('no copy could answer is not the same as nobody reacted', () {
      expect(SharedImageApi.mergeTallies(const [], anyAnswered: false), isNull);
      expect(SharedImageApi.mergeTallies(const [], anyAnswered: true), isEmpty);
    });

    test('one copy is passed through', () {
      final merged = SharedImageApi.mergeTallies(
        [
          tally([('👍', 3, true)])
        ],
        anyAnswered: true,
      )!;

      expect(merged.single.count, 3);
      expect(merged.single.reactedByMe, isTrue);
    });

    test('the viewer, who reacted on every copy, is counted once', () {
      // A tap writes to both copies, so both report it back.
      final merged = SharedImageApi.mergeTallies(
        [
          tally([('👍', 1, true)]),
          tally([('👍', 1, true)]),
        ],
        anyAnswered: true,
      )!;

      expect(merged.single.count, 1, reason: 'one person tapped once');
      expect(merged.single.reactedByMe, isTrue);
    });

    test('other people on each copy still add up', () {
      final merged = SharedImageApi.mergeTallies(
        [
          tally([('👍', 2, true)]), // me + one other here
          tally([('👍', 3, true)]), // me + two others there
        ],
        anyAnswered: true,
      )!;

      // Three other accounts, plus me once.
      expect(merged.single.count, 4);
    });

    test('a reaction only the other copy holds is not discounted', () {
      final merged = SharedImageApi.mergeTallies(
        [
          tally([('👍', 1, true)]),
          tally([('❤️', 1, false)]),
        ],
        anyAnswered: true,
      )!;

      expect(merged.map((r) => (r.emoji, r.count)).toSet(),
          {('👍', 1), ('❤️', 1)});
    });

    test('ordered by count, ties broken on emoji so tabs do not shuffle', () {
      final merged = SharedImageApi.mergeTallies(
        [
          tally([('🎉', 1, false), ('👍', 5, false), ('❤️', 1, false)]),
        ],
        anyAnswered: true,
      )!;

      expect(merged.first.emoji, '👍');
      expect(merged.map((r) => r.emoji).skip(1), ['❤️', '🎉']);
    });
  });
}

/// Which copies a tap has to touch. The interesting cases are the ones where the
/// copies disagree, which is what a removal scoped to one server produces.
void _copySelection() {
  const a = 'inst_1';
  const b = 'inst_2';
  const both = [a, b];
  const thumb = '\u{1F44D}';

  List<String> toggle({
    required Map<String, Set<String>> mine,
    required bool on,
    String? onlyOn,
  }) =>
      SharedImageApi.copiesToToggle(
        writable: both,
        mineByInstance: mine,
        emoji: thumb,
        on: on,
        onlyOn: onlyOn,
      );

  group('copiesToToggle', () {
    test('the feed reacts on every copy', () {
      expect(toggle(mine: const {}, on: true), both,
          reason: 'a reaction is only seen on the server holding it');
    });

    test('a gallery reacts on its own server alone', () {
      expect(toggle(mine: const {}, on: true, onlyOn: a), [a]);
    });

    test('a copy that already has it is left alone', () {
      // Toggling it there would take it away.
      expect(
        toggle(mine: {
          a: {thumb}
        }, on: true),
        [b],
      );
    });

    test('reacting in a gallery that already holds it changes nothing', () {
      expect(
        toggle(
          mine: {
            a: {thumb}
          },
          on: true,
          onlyOn: a,
        ),
        isEmpty,
      );
    });

    test('removing from the cross-group feed clears every copy', () {
      expect(
        toggle(mine: {
          a: {thumb},
          b: {thumb}
        }, on: false),
        both,
      );
    });

    test('removing in a gallery clears that server only', () {
      expect(
        toggle(
          mine: {
            a: {thumb},
            b: {thumb}
          },
          on: false,
          onlyOn: a,
        ),
        [a],
        reason: 'the other server keeps its own, which the feed still shows',
      );
    });

    test('removing where the copies already disagree touches nothing extra',
        () {
      // What a scoped removal leaves behind: gone on A, still on B.
      expect(
        toggle(
          mine: {
            a: <String>{},
            b: {thumb}
          },
          on: false,
          onlyOn: a,
        ),
        isEmpty,
      );
      // And from the feed, only B has anything left to clear.
      expect(
        toggle(mine: {
          a: <String>{},
          b: {thumb}
        }, on: false),
        [b],
      );
    });

    test('reacting from the feed after a scoped removal restores that copy',
        () {
      expect(
        toggle(mine: {
          a: <String>{},
          b: {thumb}
        }, on: true),
        [a],
      );
    });

    test('reacting again in the gallery restores only its own copy', () {
      expect(
        toggle(
          mine: {
            a: <String>{},
            b: {thumb}
          },
          on: true,
          onlyOn: a,
        ),
        [a],
      );
    });
  });
}
