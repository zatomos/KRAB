import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/push_helper.dart';

Uint8List body(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('decodePushPayload', () {
    test('decodes the payload the notify functions actually send', () {
      final data = decodePushPayload(body(jsonEncode({
        'type': 'new_image',
        'image_id': 'abc-123',
        'group_id': 'grp-456',
        'group_ids': 'grp-456,grp-789',
      })));

      expect(data, {
        'type': 'new_image',
        'image_id': 'abc-123',
        'group_id': 'grp-456',
        'group_ids': 'grp-456,grp-789',
      });
    });

    test('stringifies non-string values rather than throwing', () {
      // A Map<String, String> cast on a JSON number would fail at the call site,
      // far from here, so the coercion happens up front.
      final data = decodePushPayload(body('{"type":"new_reaction","count":3}'));

      expect(data?['count'], '3');
      expect(data?['count'], isA<String>());
    });

    test('drops a payload that is not a JSON object', () {
      expect(decodePushPayload(body('"just a string"')), isNull);
      expect(decodePushPayload(body('[1,2,3]')), isNull);
    });

    test('drops malformed JSON instead of throwing', () {
      expect(decodePushPayload(body('{not json')), isNull);
    });

    test('drops non-UTF8 bytes instead of throwing', () {
      expect(decodePushPayload(Uint8List.fromList([0xff, 0xfe, 0xfd])), isNull);
    });
  });
}
