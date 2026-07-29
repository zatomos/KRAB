import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/instance/instance_bootstrap.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two servers, the second on a different Firebase project.
Map<String, Object> _twoInstances() => {
      InstanceRegistry.prefsKey: jsonEncode([
        {
          'id': 'inst_1',
          'url': 'https://one.example',
          'anon_key': 'k',
          'config': {
            'fcm_app_id': 'a1',
            'fcm_api_key': 'k1',
            'fcm_sender_id': '1111',
            'fcm_project_id': 'p1',
          },
        },
        {
          'id': 'inst_2',
          'url': 'https://two.example',
          'anon_key': 'k',
          'config': {
            'fcm_app_id': 'a2',
            'fcm_api_key': 'k2',
            'fcm_sender_id': '2222',
            'fcm_project_id': 'p2',
          },
        },
      ]),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(_twoInstances());
    await InstanceRegistry.instance.load();
  });

  group('instanceForPayload', () {
    test('routes on the URL the server stamped', () async {
      final instance =
          instanceForPayload({'instance_url': 'https://two.example'});

      expect(instance?.id, 'inst_2',
          reason: 'an image id only means something on the server that '
              'issued it');
    });

    test('ignores a trailing slash and case', () async {
      final instance =
          instanceForPayload({'instance_url': 'HTTPS://Two.Example/'});

      expect(instance?.id, 'inst_2');
    });

    test('drops a message from a server we are not connected to', () async {
      final instance =
          instanceForPayload({'instance_url': 'https://three.example'});

      expect(instance, isNull,
          reason: 'answering it against another account would show the wrong '
              'photo, or leak that one exists');
    });

    test('falls back to the sender when the server stamped nothing', () async {
      final instance = instanceForPayload(const {}, senderId: '2222');

      expect(instance?.id, 'inst_2',
          reason: 'a server on an older build still has to reach its own user');
    });

    test('an ambiguous sender is not enough to route on', () async {
      SharedPreferences.setMockInitialValues({
        InstanceRegistry.prefsKey: jsonEncode([
          {
            'id': 'inst_1',
            'url': 'https://one.example',
            'anon_key': 'k',
            'config': {'fcm_sender_id': '1111'},
          },
          {
            'id': 'inst_2',
            'url': 'https://two.example',
            'anon_key': 'k',
            'config': {'fcm_sender_id': '1111'},
          },
        ]),
      });
      await InstanceRegistry.instance.load();

      // Two servers sharing one Firebase project: the sender says nothing
      // about which of them sent this.
      final instance = instanceForPayload(const {}, senderId: '1111');

      expect(instance, isNull,
          reason: 'with no default server there is nothing to fall back to, '
              'and picking one would answer the wrong account');
    });

    test('a payload this device wrote is routed the same way', () async {
      // Notification tap payloads carry the URL too, so there is one rule for
      // routing rather than one per source.
      final instance =
          instanceForPayload({'instance_url': 'https://two.example'});

      expect(instance?.id, 'inst_2');
    });

    test('drops an unidentifiable message when several servers are connected',
        () async {
      final instance = instanceForPayload(const {});

      expect(instance, isNull,
          reason: 'showing it against an arbitrary server is worse than not '
              'showing it');
    });

    test('resolves an unidentifiable message when there is only one server',
        () async {
      SharedPreferences.setMockInitialValues({
        InstanceRegistry.prefsKey: jsonEncode([
          {'id': 'inst_1', 'url': 'https://one.example', 'anon_key': 'k'},
        ]),
      });
      await InstanceRegistry.instance.load();

      final instance = instanceForPayload(const {});

      expect(instance?.id, 'inst_1',
          reason: 'one connected server is not a guess, it is the answer');
    });
  });
}
