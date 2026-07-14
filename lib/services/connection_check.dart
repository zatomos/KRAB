import 'package:dio/dio.dart';

/// Outcome of probing an instance from the connect screen.
enum ConnectionCheckResult {
  /// The instance answered and accepted the anon key.
  ok,

  /// The instance answered but rejected the key (wrong anon key, or the URL
  /// points at something that isn't this KRAB backend).
  badKey,

  /// Nothing answered: wrong URL, no network, or the server is down.
  unreachable,
}

/// Checks that the url is a reachable Supabase instance accepting anonKey.
Future<ConnectionCheckResult> testConnection(String url, String anonKey) async {
  final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    // Inspect the status ourselves rather than have dio throw on 4xx/5xx.
    validateStatus: (_) => true,
  ));

  try {
    final res = await dio.get(
      '$base/auth/v1/settings',
      options: Options(headers: {
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
      }),
    );
    final code = res.statusCode ?? 0;
    if (code == 200) return ConnectionCheckResult.ok;
    if (code == 401 || code == 403) return ConnectionCheckResult.badKey;
    return ConnectionCheckResult.unreachable;
  } catch (_) {
    return ConnectionCheckResult.unreachable;
  } finally {
    dio.close();
  }
}
