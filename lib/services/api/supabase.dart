import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:krab/config.dart';
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/services/avatar_cache.dart';
import 'package:krab/services/image_disk_cache.dart';
import 'package:krab/services/exif_stripper.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/push_helper.dart';
import 'package:krab/services/reaction_cache.dart';
import 'package:krab/services/viewer_cache.dart';
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
part 'supabase_account.dart';

final supabase = Supabase.instance.client;

/// Response Wrapper
class SupabaseResponse<T> {
  final bool success;
  final T? data;
  final String? error;

  /// The call failed because the device could not reach the server
  final bool offline;

  SupabaseResponse({
    required this.success,
    this.data,
    this.error,
    this.offline = false,
  });
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
      return SupabaseResponse(
          success: false, error: response['error']?.toString());
    }
    return SupabaseResponse(success: true, data: parse?.call(response));
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error $errorContext: $error");
  }
}
