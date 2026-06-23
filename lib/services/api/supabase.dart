import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/services/background_session.dart';
import 'package:krab/services/fcm_helper.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

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

  SupabaseResponse({required this.success, this.data, this.error});
}

/// Whether error looks like a transient network failure worth retrying.
bool _isTransientError(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  final message = error.toString().toLowerCase();
  return message.contains('socket') ||
      message.contains('timeout') ||
      message.contains('connection');
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
