import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/auth/app_auth.dart';

/// Stands in for flutter_secure_storage
class _FakeSecureStorage {
  final Map<String, String> items = {};
  bool throwOnRead = false;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
      if (call.method == 'read') {
        if (throwOnRead) throw PlatformException(code: 'boom');
        return items[call.arguments['key'] as String];
      }
      if (call.method == 'write') {
        items[call.arguments['key'] as String] =
            call.arguments['value'] as String;
        return null;
      }
      if (call.method == 'delete') {
        items.remove(call.arguments['key'] as String);
        return null;
      }
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
  }
}

String _session({String refresh = 'r-token'}) => jsonEncode({
      'access_token': 'a-token',
      'refresh_token': refresh,
      'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeSecureStorage storage;

  setUp(() {
    storage = _FakeSecureStorage()..install();
  });

  test('no session stored means signed out', () async {
    expect(await AppAuth.instance.hasStoredSession(), isFalse);
  });

  test('a session another isolate stored is seen without loading it', () async {
    expect(AppAuth.instance.isLoggedIn, isFalse,
        reason: 'in-memory state is what made this wrong');

    storage.items['krab_session'] = _session();

    expect(await AppAuth.instance.hasStoredSession(), isTrue,
        reason: 'storage is the only thing every isolate agrees on');
  });

  test('a stored session with no refresh token is not a session', () async {
    storage.items['krab_session'] = _session(refresh: '');
    expect(await AppAuth.instance.hasStoredSession(), isFalse);
  });

  test('unreadable storage does not claim a sign-out', () async {
    storage.throwOnRead = true;
    expect(await AppAuth.instance.hasStoredSession(), isTrue,
        reason: 'a storage failure is not a sign-out; claiming one would blank '
            'the widget over a transient error');
  });

  test('garbage in storage does not claim a sign-out', () async {
    storage.items['krab_session'] = 'not json';
    expect(await AppAuth.instance.hasStoredSession(), isTrue);
  });
}
