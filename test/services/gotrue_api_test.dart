import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/auth/gotrue_api.dart';

/// A stand-in for Dio's HTTP layer. Instead of hitting the network it records
/// the outgoing request and returns whatever the test tells it to.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._respond);

  /// Given the outgoing request, returns the response body to hand back.
  /// May throw a DioException to simulate a connection failure.
  final ResponseBody Function(RequestOptions options) _respond;

  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return _respond(options);
  }

  @override
  void close({bool force = false}) {}
}

/// Builds a JSON ResponseBody with the given status code.
ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

/// Wires a GotrueApi to a fake adapter.
/// Returns both so tests can inspect the recorded request afterwards.
(GotrueApi, _FakeAdapter) _apiReturning(ResponseBody Function(RequestOptions) r) {
  final adapter = _FakeAdapter(r);
  final dio = Dio()..httpClientAdapter = adapter;
  final api = GotrueApi('https://auth.example', 'anon-key-123', dio: dio);
  return (api, adapter);
}

void main() {
  group('request building', () {
    test('passwordGrant posts email/password with the password grant', () async {
      final (api, adapter) =
          _apiReturning((_) => _json({'access_token': 'a', 'refresh_token': 'r'}));

      final session = await api.passwordGrant('me@x.com', 'pw');

      final req = adapter.lastRequest!;
      expect(req.method, 'POST');
      expect(req.uri.path, '/auth/v1/token');
      expect(req.uri.queryParameters['grant_type'], 'password');
      expect(req.data, {'email': 'me@x.com', 'password': 'pw'});
      expect(req.headers['apikey'], 'anon-key-123');
      // Returns the parsed session body.
      expect(session['access_token'], 'a');
      expect(session['refresh_token'], 'r');
    });

    test('refreshGrant uses the refresh_token grant', () async {
      final (api, adapter) =
          _apiReturning((_) => _json({'access_token': 'a', 'refresh_token': 'r2'}));

      await api.refreshGrant('old-refresh');

      final req = adapter.lastRequest!;
      expect(req.uri.queryParameters['grant_type'], 'refresh_token');
      expect(req.data, {'refresh_token': 'old-refresh'});
    });

    test('signUp posts to the signup endpoint', () async {
      final (api, adapter) = _apiReturning((_) => _json({'id': 'u1'}));

      await api.signUp('new@x.com', 'pw');

      final req = adapter.lastRequest!;
      expect(req.uri.path, '/auth/v1/signup');
      expect(req.data, {'email': 'new@x.com', 'password': 'pw'});
    });

    test('signUp carries user metadata when provided', () async {
      final (api, adapter) = _apiReturning((_) => _json({'id': 'u1'}));

      await api.signUp('new@x.com', 'pw', data: {'username': 'bob'});

      expect(adapter.lastRequest!.data, {
        'email': 'new@x.com',
        'password': 'pw',
        'data': {'username': 'bob'},
      });
    });

    test('signUp passes redirect_to when provided', () async {
      final (api, adapter) = _apiReturning((_) => _json({'id': 'u1'}));

      await api.signUp('new@x.com', 'pw',
          redirectTo: 'https://app/confirmed.html');

      expect(adapter.lastRequest!.uri.queryParameters['redirect_to'],
          'https://app/confirmed.html');
    });

    test('resendSignup posts a signup-type resend', () async {
      final (api, adapter) = _apiReturning((_) => _json({}));

      await api.resendSignup('new@x.com');

      final req = adapter.lastRequest!;
      expect(req.uri.path, '/auth/v1/resend');
      expect(req.data, {'type': 'signup', 'email': 'new@x.com'});
    });

    test('updatePassword sends the bearer token', () async {
      final (api, adapter) = _apiReturning((_) => _json({}));

      await api.updatePassword('access-tok', 'newpw');

      final req = adapter.lastRequest!;
      expect(req.method, 'PUT');
      expect(req.uri.path, '/auth/v1/user');
      expect(req.headers['Authorization'], 'Bearer access-tok');
      expect(req.data, {'password': 'newpw'});
    });

    test('recover omits the redirect query when none is given', () async {
      final (api, adapter) = _apiReturning((_) => _json({}));

      await api.recover('me@x.com');

      expect(adapter.lastRequest!.uri.queryParameters.containsKey('redirect_to'),
          isFalse);
    });

    test('recover includes redirect_to when provided', () async {
      final (api, adapter) = _apiReturning((_) => _json({}));

      await api.recover('me@x.com', redirectTo: 'https://app/reset');

      expect(adapter.lastRequest!.uri.queryParameters['redirect_to'],
          'https://app/reset');
    });
  });

  group('response handling', () {
    test('returns an empty map when the body is not a JSON object', () async {
      final (api, _) = _apiReturning((_) => _json([1, 2, 3]));
      expect(await api.refreshGrant('r'), isEmpty);
    });
  });

  group('error mapping', () {
    test('a rejected request becomes GotrueAuthException with the error code',
        () async {
      final (api, _) = _apiReturning(
          (_) => _json({'error_code': 'invalid_grant'}, status: 400));

      expect(
        () => api.passwordGrant('me@x.com', 'wrong'),
        throwsA(isA<GotrueAuthException>()
            .having((e) => e.code, 'code', 'invalid_grant')),
      );
    });

    test('error code extraction prefers error_code over other keys', () async {
      final (api, _) = _apiReturning((_) => _json({
            'error_code': 'first',
            'code': 'second',
            'msg': 'third',
          }, status: 400));

      expect(
        () => api.passwordGrant('a', 'b'),
        throwsA(isA<GotrueAuthException>().having((e) => e.code, 'code', 'first')),
      );
    });

    test('falls back to msg when no explicit code key is present', () async {
      final (api, _) = _apiReturning(
          (_) => _json({'msg': 'Email not confirmed'}, status: 400));

      expect(
        () => api.passwordGrant('a', 'b'),
        throwsA(isA<GotrueAuthException>()
            .having((e) => e.code, 'code', 'Email not confirmed')),
      );
    });

    test('falls back to auth_error when the body has no known keys', () async {
      final (api, _) =
          _apiReturning((_) => _json({'unexpected': true}, status: 400));

      expect(
        () => api.passwordGrant('a', 'b'),
        throwsA(isA<GotrueAuthException>()
            .having((e) => e.code, 'code', 'auth_error')),
      );
    });

    test('a connection failure becomes GotrueNetworkException', () async {
      final (api, _) = _apiReturning((options) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        );
      });

      expect(
        () => api.refreshGrant('r'),
        throwsA(isA<GotrueNetworkException>()),
      );
    });
  });

  group('logout', () {
    test('sends scope=local with the bearer token', () async {
      final (api, adapter) = _apiReturning((_) => _json({}));

      await api.logout('access-tok');

      final req = adapter.lastRequest!;
      expect(req.uri.path, '/auth/v1/logout');
      expect(req.uri.queryParameters['scope'], 'local');
      expect(req.headers['Authorization'], 'Bearer access-tok');
    });

    test('swallows server errors and completes normally', () async {
      final (api, _) =
          _apiReturning((_) => _json({'error_code': 'nope'}, status: 401));

      // Should not throw even though the server rejected it.
      await expectLater(api.logout('access-tok'), completes);
    });

    test('swallows network errors and completes normally', () async {
      final (api, _) = _apiReturning((options) {
        throw DioException.connectionError(
            requestOptions: options, reason: 'offline');
      });

      await expectLater(api.logout('access-tok'), completes);
    });
  });
}
