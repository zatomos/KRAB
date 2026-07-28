import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/home_widget_updater.dart';

/// Stands in for the Android side of home_widget
class _FakeWidgetHost {
  final Map<String, Object?> data = {};
  final List<String> redraws = [];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'),
            (call) async {
      switch (call.method) {
        case 'saveWidgetData':
          data[call.arguments['id'] as String] = call.arguments['data'];
          return true;
        case 'getWidgetData':
          return data[call.arguments['id'] as String] ??
              call.arguments['defaultValue'];
        case 'updateWidget':
          redraws.add(call.arguments['name'] as String);
          return true;
      }
      return null;
    });
  }
}

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

  void signIn() => items['krab_session'] = jsonEncode({
        'access_token': 'a',
        'refresh_token': 'r',
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      });

  void signOut() => items.remove('krab_session');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeWidgetHost host;
  late _FakeSecureStorage storage;

  setUp(() {
    host = _FakeWidgetHost()..install();
    storage = _FakeSecureStorage()..install();
  });

  test('no session raises the flag on both widget kinds', () async {
    storage.signOut();

    expect(await refreshWidgetAuthState(), isFalse);
    expect(host.data['widgetSignedOut'], isTrue);
    expect(host.redraws,
        containsAll(['HomeScreenWidget', 'HomeScreenWidgetMulti']),
        reason: 'both kinds have to be told, or one keeps stale photos');
  });

  test('signing back in clears it and redraws', () async {
    storage.signOut();
    await refreshWidgetAuthState();
    host.redraws.clear();

    storage.signIn();

    expect(await refreshWidgetAuthState(), isTrue);
    expect(host.data['widgetSignedOut'], isFalse,
        reason: 'a stuck flag leaves the overlay over photos that are fine');
    expect(host.redraws,
        containsAll(['HomeScreenWidget', 'HomeScreenWidgetMulti']));
  });

  test('a session written by another isolate is seen', () async {
    storage.signIn();

    expect(await refreshWidgetAuthState(), isTrue);
  });

  test('an unchanged answer does not redraw', () async {
    storage.signIn();
    await refreshWidgetAuthState();
    host.redraws.clear();

    await refreshWidgetAuthState();

    expect(host.redraws, isEmpty,
        reason: 'this runs on every resume; a redraw reloads every bitmap');
  });

  test('the first answer always redraws', () async {
    storage.signIn();

    await refreshWidgetAuthState();

    expect(host.redraws,
        containsAll(['HomeScreenWidget', 'HomeScreenWidgetMulti']));
  });
}
