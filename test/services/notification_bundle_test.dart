import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/notification_summaries.dart';

void main() {
  final now = DateTime(2026, 8, 17, 12);

  BundleChild child(
    BundleKind kind, {
    int id = 1,
    String line = 'a line',
    int count = 1,
    Duration ago = Duration.zero,
  }) =>
      BundleChild(
        id: id,
        kind: kind,
        line: line,
        count: count,
        at: now.subtract(ago),
      );

  group('summarizeBundle', () {
    test('nothing under it is a summary that has to come down', () {
      final summary = summarizeBundle(const []);

      expect(summary.children, 0);
      expect(summary.isWorthPosting, isFalse);
    });

    test('one notification heads nothing', () {
      // A summary above a single notification would only say what it already
      // says.
      expect(
          summarizeBundle([child(BundleKind.image)]).isWorthPosting, isFalse);
    });

    test('two notifications are worth collapsing', () {
      final summary = summarizeBundle([
        child(BundleKind.image, id: 1),
        child(BundleKind.comment, id: 2),
      ]);

      expect(summary.isWorthPosting, isTrue);
      expect(summary.children, 2);
    });

    test('the newest is read first', () {
      final summary = summarizeBundle([
        child(BundleKind.image,
            id: 1, line: 'older', ago: const Duration(hours: 2)),
        child(BundleKind.image, id: 2, line: 'newest'),
        child(BundleKind.image,
            id: 3, line: 'middle', ago: const Duration(hours: 1)),
      ]);

      expect(summary.lines, ['newest', 'middle', 'older']);
    });

    test('a notification standing for several events counts them all', () {
      final summary = summarizeBundle([
        child(BundleKind.comment, id: 1, count: 5),
        child(BundleKind.image, id: 2),
      ]);

      expect(summary.children, 2);
      expect(summary.comments, 5);
      expect(summary.images, 1);
      expect(summary.total, 6);
    });

    test('each kind is counted on its own', () {
      final summary = summarizeBundle([
        child(BundleKind.image, id: 1),
        child(BundleKind.image, id: 2),
        child(BundleKind.comment, id: 3, count: 3),
        child(BundleKind.reaction, id: 4, count: 2),
      ]);

      expect((summary.images, summary.comments, summary.reactions), (2, 3, 2));
    });

    test('a child with nothing to say is still counted', () {
      final summary = summarizeBundle([
        child(BundleKind.image, id: 1, line: ''),
        child(BundleKind.image, id: 2, line: 'said something'),
      ]);

      expect(summary.lines, ['said something']);
      expect(summary.children, 2, reason: 'it is still on the screen');
    });
  });

  group('bundleSummaryText', () {
    String text(BundleSummary summary) => bundleSummaryText(
          summary,
          images: (n) => '$n images',
          comments: (n) => '$n comments',
          reactions: (n) => '$n reactions',
        );

    test('names only the kinds that are there', () {
      final summary = summarizeBundle([
        child(BundleKind.image, id: 1),
        child(BundleKind.image, id: 2),
        child(BundleKind.comment, id: 3, count: 3),
      ]);

      expect(text(summary), '2 images, 3 comments');
    });

    test('one kind reads on its own', () {
      final summary = summarizeBundle([
        child(BundleKind.reaction, id: 1, count: 4),
        child(BundleKind.reaction, id: 2),
      ]);

      expect(text(summary), '5 reactions');
    });

    test('the order is fixed, whichever arrived first', () {
      final summary = summarizeBundle([
        child(BundleKind.reaction, id: 1),
        child(BundleKind.comment, id: 2),
        child(BundleKind.image, id: 3, ago: const Duration(hours: 5)),
      ]);

      expect(text(summary), '1 images, 1 comments, 1 reactions');
    });
  });
}
