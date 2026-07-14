import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:krab/config.dart';
import 'package:krab/services/cache/profile_picture_cache.dart';
import 'package:krab/services/cache/avatar_cache.dart';
import 'package:krab/services/cache/image_disk_cache.dart';
import 'package:krab/services/exif_stripper.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/push_helper.dart';
import 'package:krab/services/cache/reaction_cache.dart';
import 'package:krab/services/cache/viewer_cache.dart';
import 'package:krab/user_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:krab/models/group.dart';
import 'package:krab/models/group_invite.dart';
import 'package:krab/models/group_member.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/image_details.dart';
import 'package:krab/models/user.dart' as krab_user;

part 'supabase_groups.dart';
part 'supabase_images.dart';
part 'supabase_comments.dart';
part 'supabase_reactions.dart';
part 'supabase_account.dart';

final supabase = Supabase.instance.client;

/// Response Wrapper
class SupabaseResponse<T> {
  final bool success;
  final T? data;

  /// Why the call failed, as something we can display to the user.
  final String? error;

  /// The call failed because the device could not reach the server
  final bool offline;

  const SupabaseResponse({
    required this.success,
    this.data,
    this.error,
    this.offline = false,
  });
}

/// The device could not reach the server.
const String errorNetwork = 'network_error';

/// The server was reached, but the call failed.
const String errorServer = 'server_error';

/// The call needs a signed-in user and there isn't one.
const String errorNotLoggedIn = 'not_logged_in';

const String errorPhotoTooLarge = 'photo_too_large';

const String errorNameTooShort = 'name_too_short';

/// Failure codes KRAB produces, which the UI translates.
const Set<String> errorCodes = {
  errorNetwork,
  errorServer,
  errorNotLoggedIn,
  errorPhotoTooLarge,
  errorNameTooShort,
};

/// Turn a thrown exception into a failure the UI can show.
SupabaseResponse<T> _failure<T>(Object error, String what) {
  final offline = _isTransientError(error);
  debugPrint('Supabase: $what failed: $error');
  return SupabaseResponse(
    success: false,
    offline: offline,
    error: offline ? errorNetwork : errorServer,
  );
}

/// Whether error looks like a transient network failure worth retrying.
bool _isTransientError(Object error) {
  if (error is PostgrestException ||
      error is StorageException ||
      error is FunctionException ||
      error is AuthException) {
    return false;
  }

  if (error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      error is HandshakeException) {
    return true;
  }

  // The HTTP clients underneath postgrest/storage wrap a dead connection in
  // their own exception types, which aren't exported for us to catch by name.
  final message = error.toString().toLowerCase();
  return message.contains('socketexception') ||
      message.contains('clientexception') ||
      message.contains('failed host lookup') ||
      message.contains('connection refused') ||
      message.contains('connection reset') ||
      message.contains('connection closed') ||
      message.contains('connection terminated') ||
      message.contains('network is unreachable') ||
      message.contains('timeoutexception') ||
      message.contains('timed out');
}

/// Runs action, retrying on transient network errors with exponential
/// backoff. Non-transient errors are rethrown immediately.
Future<T> _withRetry<T>(
  Future<T> Function() action, {
  int maxAttempts = 3,
}) async {
  var attempt = 0;
  while (true) {
    attempt++;
    try {
      return await action();
    } catch (error) {
      if (attempt >= maxAttempts || !_isTransientError(error)) rethrow;
      await Future.delayed(Duration(milliseconds: 300 * attempt * attempt));
    }
  }
}

/// Calls a Supabase RPC that returns a `{success, error, ...}` JSON object and
/// wraps the common success/error/try-catch handling.
Future<SupabaseResponse<T>> _rpc<T>(
  String fn, {
  Map<String, dynamic>? params,
  required String errorContext,
  T Function(dynamic response)? parse,
}) async {
  try {
    final response = await supabase.rpc(fn, params: params);
    if (response is Map && response['success'] == false) {
      // The server explains its own refusals; pass its message through.
      return SupabaseResponse(
          success: false, error: response['error']?.toString() ?? errorServer);
    }
    return SupabaseResponse(success: true, data: parse?.call(response));
  } catch (error) {
    return _failure(error, errorContext);
  }
}
