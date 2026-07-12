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

  group('JSON serialization', () {
    test('round-trips through json without a parent', () {
      final original = _c('x');
      final restored = commentFromJson(commentToJson(original));

      expect(restored.id, original.id);
      expect(restored.userId, original.userId);
      expect(restored.text, original.text);
      expect(restored.createdAt, original.createdAt);
      expect(restored.parentId, isNull);
      expect(restored.replies, isEmpty);
    });

    test('round-trips a parent id', () {
      final restored =
          commentFromJson(commentToJson(_c('x', parentId: 'p')));
      expect(restored.parentId, 'p');
    });

    test('string helpers round-trip', () {
      final restored = commentFromJsonString(commentToJsonString(_c('s')));
      expect(restored.id, 's');
    });
  });

  group('copyWith', () {
    test('overrides only the given field', () {
      final updated = _c('a').copyWith(text: 'edited');
      expect(updated.id, 'a');
      expect(updated.text, 'edited');
    });

    test('preserves all fields when nothing is passed', () {
      final original = _c('a', parentId: 'p');
      final copy = original.copyWith();
      expect(copy.id, original.id);
      expect(copy.parentId, original.parentId);
      expect(copy.createdAt, original.createdAt);
    });
  });
}
