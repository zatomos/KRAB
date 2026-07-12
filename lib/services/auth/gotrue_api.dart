import 'package:dio/dio.dart';

/// A transient network failure (no HTTP response). The caller should keep the
/// current session and retry later.
class GotrueNetworkException implements Exception {
  const GotrueNetworkException();
}

/// The server rejected the request.
class GotrueAuthException implements Exception {
  const GotrueAuthException(this.code);
  final String code;
}

/// Thin, stateless client over the GoTrue REST API. This is the only thing that
/// talks to auth.
class GotrueApi {
  GotrueApi(this._url, this._anonKey, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
            ));

  final String _url;
  final String _anonKey;

  final Dio _dio;

  Map<String, String> _headers({String? bearer}) => {
        'apikey': _anonKey,
        'Content-Type': 'application/json',
        if (bearer != null) 'Authorization': 'Bearer $bearer',
      };

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    String? bearer,
  }) async {
    try {
      final res = await _dio.request(
        '$_url$path',
        data: body,
        queryParameters: query,
        options: Options(method: method, headers: _headers(bearer: bearer)),
      );
      final data = res.data;
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on DioException catch (e) {
      // No response object => connection/timeout => transient.
      if (e.response == null) throw const GotrueNetworkException();
      throw GotrueAuthException(_extractCode(e.response!.data));
    }
  }

  String _extractCode(dynamic data) {
    if (data is Map) {
      for (final key in ['error_code', 'code', 'error']) {
        final v = data[key];
        if (v is String && v.isNotEmpty) return v;
      }
      for (final key in ['msg', 'error_description', 'message']) {
        final v = data[key];
        if (v is String && v.isNotEmpty) return v;
      }
    }
    return 'auth_error';
  }

  /// Exchange email and password for a session.
  Future<Map<String, dynamic>> passwordGrant(String email, String password) =>
      _request('POST', '/auth/v1/token',
          query: {'grant_type': 'password'},
          body: {'email': email, 'password': password});

  /// Exchange a refresh token for a new session (rotates the chain).
  Future<Map<String, dynamic>> refreshGrant(String refreshToken) =>
      _request('POST', '/auth/v1/token',
          query: {'grant_type': 'refresh_token'},
          body: {'refresh_token': refreshToken});

  /// Create a new user. data is stored as the user's metadata used here
  /// to carry the chosen username. When email confirmation is enabled,
  /// the response contains no session.
  Future<Map<String, dynamic>> signUp(String email, String password,
          {Map<String, dynamic>? data, String? redirectTo}) =>
      _request('POST', '/auth/v1/signup',
          query: redirectTo == null ? null : {'redirect_to': redirectTo},
          body: {
            'email': email,
            'password': password,
            if (data != null) 'data': data,
          });

  /// Re-send the signup confirmation email for an unconfirmed account.
  Future<void> resendSignup(String email, {String? redirectTo}) => _request(
        'POST',
        '/auth/v1/resend',
        query: redirectTo == null ? null : {'redirect_to': redirectTo},
        body: {'type': 'signup', 'email': email},
      ).then((_) {});

  /// Revoke the session server-side (best-effort).
  Future<void> logout(String accessToken) async {
    try {
      await _request('POST', '/auth/v1/logout',
          query: {'scope': 'local'}, bearer: accessToken);
    } catch (_) {}
  }

  /// Change the current user's password.
  Future<void> updatePassword(String accessToken, String newPassword) =>
      _request('PUT', '/auth/v1/user',
          body: {'password': newPassword}, bearer: accessToken).then((_) {});

  /// Send a password reset email.
  Future<void> recover(String email, {String? redirectTo}) => _request(
        'POST',
        '/auth/v1/recover',
        query: redirectTo == null ? null : {'redirect_to': redirectTo},
        body: {'email': email},
      ).then((_) {});
}
