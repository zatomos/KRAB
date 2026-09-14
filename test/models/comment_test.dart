import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/comment.dart';

Comment _c(String id, {String? parentId, DateTime? deletedAt}) => Comment(
      id: id,
      userId: 'u',
      text: 'text-$id',
      createdAt: DateTime.utc(2026, 1, 1),
      parentId: parentId,
      deletedAt: deletedAt,
    );

void main() {
  group('buildCommentTree', () {
    test('keeps top-level comments as roots', () {
      final roots = buildCommentTree([_c('a'), _c('b')]);
      expect(roots.map((c) => c.id), ['a', 'b']);
      expect(roots.every((c) => c.replies.isEmpty), isTrue);
    });

    test('nests replies under their parent', () {
      final roots = buildCommentTree([
        _c('root'),
        _c('reply1', parentId: 'root'),
        _c('reply2', parentId: 'root'),
      ]);

      expect(roots.length, 1);
      expect(roots.single.id, 'root');
      expect(roots.single.replies.map((c) => c.id), ['reply1', 'reply2']);
    });

    test('treats a reply with a missing parent as a root (orphan)', () {
      final roots = buildCommentTree([
        _c('root'),
        _c('orphan', parentId: 'does-not-exist'),
      ]);

      expect(roots.map((c) => c.id), containsAll(['root', 'orphan']));
      expect(roots.length, 2);
    });

    test('returns an empty list for empty input', () {
      expect(buildCommentTree([]), isEmpty);
    });

    test('a deleted parent keeps its replies in the thread', () {
      final roots = buildCommentTree([
        _c('root', deletedAt: DateTime.utc(2026, 1, 2)),
        _c('reply', parentId: 'root'),
      ]);

      expect(roots.single.isDeleted, isTrue);
      expect(roots.single.replies.map((c) => c.id), ['reply']);
      expect(roots.single.replies.single.isDeleted, isFalse);
    });
  });

  group('isDeleted', () {
    test('is false without a deletion time', () {
      expect(_c('a').isDeleted, isFalse);
    });

    test('is true once deleted', () {
      expect(_c('a', deletedAt: DateTime.utc(2026, 1, 2)).isDeleted, isTrue);
    });
  });
}
