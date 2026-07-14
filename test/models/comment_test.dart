import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/comment.dart';

Comment _c(String id, {String? parentId}) => Comment(
      id: id,
      userId: 'u',
      text: 'text-$id',
      createdAt: DateTime.utc(2026, 1, 1),
      parentId: parentId,
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
  });
}
