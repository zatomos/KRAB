import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/group.dart';

void main() {
  group('Group.fromJson', () {
    test('parses a full payload', () {
      final g = Group.fromJson({
        'id': 'g1',
        'name': 'Friends',
        'icon_url': 'http://x/i.png',
        'created_at': '2026-01-01T00:00:00Z',
        'latest_image_at': '2026-02-03T04:05:06Z',
        'invite_permission': 'admin',
        'role': 'member',
      }, instanceId: 'inst_1');

      expect(g.instanceId, 'inst_1',
          reason: 'a group is only meaningful on the instance it came from');
      expect(g.id, 'g1');
      expect(g.name, 'Friends');
      expect(g.iconUrl, 'http://x/i.png');
      expect(g.latestImageAt, DateTime.utc(2026, 2, 3, 4, 5, 6));
      expect(g.invitePermission, 'admin');
      expect(g.role, 'member');
    });

    test('leaves nullable fields null when absent', () {
      final g = Group.fromJson({
        'id': 'g2',
        'name': 'Solo',
        'created_at': '2026-01-01T00:00:00Z',
      }, instanceId: 'inst_1');

      expect(g.iconUrl, isNull);
      expect(g.latestImageAt, isNull);
      expect(g.invitePermission, isNull);
      expect(g.role, isNull);
    });
  });

  group('copyWith', () {
    test('overrides a single field', () {
      final original = Group.fromJson({
        'id': 'g1',
        'name': 'Old',
        'created_at': '2026-01-01T00:00:00Z',
      }, instanceId: 'inst_1');
      final renamed = original.copyWith(name: 'New');

      expect(renamed.id, 'g1');
      expect(renamed.name, 'New');
      expect(renamed.instanceId, 'inst_1',
          reason: 'a copy must not lose track of where the group lives');
    });
  });
}
