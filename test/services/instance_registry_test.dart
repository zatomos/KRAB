import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for flutter_secure_storage, which holds the sessions.
class _FakeSecureStorage {
  final Map<String, String> items = {};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
      switch (call.method) {
        case 'read':
          return items[call.arguments['key'] as String];
        case 'write':
          items[call.arguments['key'] as String] =
              call.arguments['value'] as String;
          return null;
        case 'delete':
          items.remove(call.arguments['key'] as String);
          return null;
        case 'readAll':
          return <String, String>{};
      }
      return null;
    });
  }
}

String _session(String refresh) => jsonEncode({
      'access_token': 'a',
      'refresh_token': refresh,
      'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeSecureStorage storage;

  setUp(() {
    storage = _FakeSecureStorage()..install();
  });

  group('migration off the single-instance layout', () {
    test('adopts the backend the old build was pointed at', () async {
      SharedPreferences.setMockInitialValues({
        'supabaseUrl': 'https://one.example/',
        'supabaseAnonKey': 'anon-key',
        'fcmAppId': 'app',
        'fcmApiKey': 'key',
        'fcmSenderId': 'sender',
        'fcmProjectId': 'project',
        'passwordResetUrl': 'https://one.example/reset',
      });

      await InstanceRegistry.instance.load();

      final instance = InstanceRegistry.instance.active!;
      expect(instance.id, 'inst_1');
      expect(instance.url, 'https://one.example',
          reason: 'a trailing slash must not make one server look like two');
      expect(instance.anonKey, 'anon-key');
      expect(instance.config.hasFcm, isTrue,
          reason: 'losing the cached FCM config would silently stop push '
              'until the next instance-config fetch');
      expect(instance.config.passwordResetUrl, 'https://one.example/reset');
    });

    test('carries the session over, so migrating is not a sign-out', () async {
      SharedPreferences.setMockInitialValues({
        'supabaseUrl': 'https://one.example',
        'supabaseAnonKey': 'anon-key',
      });
      storage.items[legacySessionStorageKey] = _session('refresh-token');

      await InstanceRegistry.instance.load();
      await InstanceRegistry.instance.loadSessions();

      expect(InstanceRegistry.instance.active!.auth.isLoggedIn, isTrue);
      expect(storage.items[sessionStorageKey('inst_1')], isNotNull);
      expect(storage.items[legacySessionStorageKey], isNull,
          reason: 'a stale copy of a live refresh token is worth nothing and '
              'would only rot');
    });

    test('scopes the favourite and muted lists to the instance', () async {
      SharedPreferences.setMockInitialValues({
        'supabaseUrl': 'https://one.example',
        'supabaseAnonKey': 'anon-key',
        'favoriteGroups': ['g1', 'g2'],
        'mutedGroups': ['g3'],
      });

      await InstanceRegistry.instance.load();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('favoriteGroups'),
          ['inst_1/g1', 'inst_1/g2']);
      expect(prefs.getStringList('mutedGroups'), ['inst_1/g3']);
    });

    test('a fresh install has nothing to connect to', () async {
      SharedPreferences.setMockInitialValues({});

      await InstanceRegistry.instance.load();

      expect(InstanceRegistry.instance.isEmpty, isTrue);
      expect(InstanceRegistry.instance.active, isNull);
    });
  });

  group('persistence', () {
    test('a connected instance survives a reload', () async {
      SharedPreferences.setMockInitialValues({});
      await InstanceRegistry.instance.load();

      await InstanceRegistry.instance
          .connect(url: 'https://two.example', anonKey: 'k2');

      await InstanceRegistry.instance.load();

      expect(InstanceRegistry.instance.all, hasLength(1));
      expect(InstanceRegistry.instance.active!.url, 'https://two.example');
    });

    test('the stored shape is a JSON array, which the native side parses',
        () async {
      SharedPreferences.setMockInitialValues({});
      await InstanceRegistry.instance.load();
      await InstanceRegistry.instance
          .connect(url: 'https://two.example', anonKey: 'k2');

      final prefs = await SharedPreferences.getInstance();
      final decoded =
          jsonDecode(prefs.getString(InstanceRegistry.prefsKey)!) as List;

      expect(decoded.single['url'], 'https://two.example');
      expect(decoded.single['config'], isA<Map>(),
          reason: 'KrabApplication reads the FCM config out of this before any '
              'Dart runs');
    });

    test('reconnecting to the same server keeps the session', () async {
      SharedPreferences.setMockInitialValues({});
      await InstanceRegistry.instance.load();

      final first = await InstanceRegistry.instance
          .connect(url: 'https://two.example/', anonKey: 'k2');
      final again = await InstanceRegistry.instance
          .connect(url: 'https://two.example', anonKey: 'k2');

      expect(InstanceRegistry.instance.all, hasLength(1),
          reason: 'the same URL twice is one instance');
      expect(again.id, first.id);
    });

    test('a rotated anon key keeps the id, so nothing local is lost', () async {
      SharedPreferences.setMockInitialValues({});
      await InstanceRegistry.instance.load();

      final first = await InstanceRegistry.instance
          .connect(url: 'https://two.example', anonKey: 'old');
      final rotated = await InstanceRegistry.instance
          .connect(url: 'https://two.example', anonKey: 'new');

      expect(rotated.id, first.id);
      expect(rotated.anonKey, 'new');
      expect(InstanceRegistry.instance.all, hasLength(1));
    });

    test('an id is never handed to a second backend', () async {
      SharedPreferences.setMockInitialValues({});
      await InstanceRegistry.instance.load();

      final first = await InstanceRegistry.instance
          .connect(url: 'https://two.example', anonKey: 'k');
      await InstanceRegistry.instance.remove(first.id);
      final second = await InstanceRegistry.instance
          .connect(url: 'https://three.example', anonKey: 'k');

      expect(second.id, isNot(first.id),
          reason: 'reusing an id would hand the new server the old one\'s '
              'session key and cached photos');
    });

    test('one unreadable entry does not take the others with it', () async {
      SharedPreferences.setMockInitialValues({
        InstanceRegistry.prefsKey: jsonEncode([
          {'id': 'inst_1', 'url': '', 'anon_key': 'k'},
          {'id': 'inst_2', 'url': 'https://ok.example', 'anon_key': 'k'},
        ]),
      });

      await InstanceRegistry.instance.load();

      expect(InstanceRegistry.instance.all, hasLength(1));
      expect(InstanceRegistry.instance.all.single.id, 'inst_2');
    });
  });

  group('sessions', () {
    test('each instance holds its own', () async {
      SharedPreferences.setMockInitialValues({
        InstanceRegistry.prefsKey: jsonEncode([
          {'id': 'inst_1', 'url': 'https://one.example', 'anon_key': 'k'},
          {'id': 'inst_2', 'url': 'https://two.example', 'anon_key': 'k'},
        ]),
      });
      storage.items[sessionStorageKey('inst_1')] = _session('r1');

      await InstanceRegistry.instance.load();
      await InstanceRegistry.instance.loadSessions();

      expect(InstanceRegistry.instance.byId('inst_1')!.auth.isLoggedIn, isTrue);
      expect(InstanceRegistry.instance.byId('inst_2')!.auth.isLoggedIn, isFalse,
          reason: 'signing into one server must not sign you into another');
    });

    test('auth events say which instance they came from', () async {
      SharedPreferences.setMockInitialValues({
        InstanceRegistry.prefsKey: jsonEncode([
          {'id': 'inst_1', 'url': 'https://one.example', 'anon_key': 'k'},
          {'id': 'inst_2', 'url': 'https://two.example', 'anon_key': 'k'},
        ]),
      });
      await InstanceRegistry.instance.load();

      final seen = <InstanceAuthEvent>[];
      final subscription =
          InstanceRegistry.instance.authEvents.listen(seen.add);

      // forgetSession is silent by design; a real sign-out is what announces.
      await InstanceRegistry.instance.byId('inst_2')!.auth.logout();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(seen, hasLength(1));
      expect(seen.single.instance.id, 'inst_2');
      expect(seen.single.status, AppAuthStatus.signedOut);
    });
  });
}
