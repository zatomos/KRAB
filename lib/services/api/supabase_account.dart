part of 'supabase.dart';

/// ------------------ PUSH SUBSCRIPTION & USER FUNCTIONS ------------------

/// Stores the caller's Web Push subscription so the backend can push to it.
///
/// [endpoint] is where the user's push service accepts messages; [p256dh] and
/// [auth] are the keys the backend needs to encrypt a payload that only this
/// device can open. All three come from the distributor, and any of
/// them can change at any launch, so this is called on every new endpoint
/// rather than once at sign-up.
Future<SupabaseResponse<void>> savePushSubscription({
  required String endpoint,
  required String p256dh,
  required String auth,
  String? username,
}) async {
  if (!AppAuth.instance.isLoggedIn) {
    return SupabaseResponse(success: false, error: "No authenticated user");
  }

  try {
    final response = await supabase.rpc("register_push_subscription", params: {
      "p_endpoint": endpoint,
      "p_p256dh": p256dh,
      "p_auth": auth,
      if (username != null) "p_username": username,
    });

    if (response["success"] == false) {
      return SupabaseResponse(
          success: false, error: response["error"]?.toString());
    }
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error saving push subscription: $error",
    );
  }
}

/// Drops the caller's Web Push subscription, so the backend stops pushing to a
/// device the user has signed out of.
Future<SupabaseResponse<void>> clearPushSubscription() async {
  if (!AppAuth.instance.isLoggedIn) {
    return SupabaseResponse(success: false, error: "No authenticated user");
  }

  try {
    await supabase.from('Users').update({
      'push_endpoint': null,
      'push_p256dh': null,
      'push_auth': null,
    }).eq('id', AppAuth.instance.currentUserId!);
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error clearing push subscription: $error",
    );
  }
}

/// This instance's VAPID public key, which the app must present to a distributor
/// to open a Web Push subscription.
Future<SupabaseResponse<String>> fetchVapidPublicKey() async {
  try {
    final res = await supabase.functions.invoke('vapid');

    final body = res.data;
    final key = body is Map ? body['vapid_public_key'] as String? : null;

    if (key == null || key.isEmpty) {
      return SupabaseResponse(
        success: false,
        error: "This instance has not configured push notifications",
      );
    }
    return SupabaseResponse(success: true, data: key);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error fetching the VAPID public key: $error",
    );
  }
}

/// Map a GoTrue error code to the app's localized error keys.
String _mapAuthError(String? code) {
  switch (code) {
    case 'invalid_credentials':
    case 'invalid_grant':
      return 'invalid_email_or_password';
    case 'user_already_exists':
    case 'email_exists':
      return 'email_already_exists';
    case 'weak_password':
      return 'password_too_weak';
    case 'email_not_confirmed':
      return 'email_not_confirmed';
    default:
      return code ?? 'auth_error';
  }
}

/// Register a new user.
///
/// Returns `data: true` when the account is immediately logged in,
/// or `data: false` when a confirmation email was sent and the user
/// must verify before logging in.
Future<SupabaseResponse<bool>> registerUser(
    String username, String email, String password) async {
  debugPrint("Registering user: $username, $email");
  // After confirming, GoTrue redirects here. When unset it falls back to the
  // server's SITE_URL. Must be allowlisted in ADDITIONAL_REDIRECT_URLS.
  final confirmUrl = dotenv.env['EMAIL_CONFIRM_URL'];
  final res = await AppAuth.instance
      .register(email, password, username: username, redirectTo: confirmUrl);
  if (!res.success) {
    return SupabaseResponse(success: false, error: _mapAuthError(res.error));
  }
  if (AppAuth.instance.isLoggedIn) {
    await PushHelper.ensureRegistered();
    return SupabaseResponse(success: true, data: true);
  }
  // Verification required; the username was stored via signup metadata and the
  // profile is created server-side, so nothing else to do until they confirm.
  return SupabaseResponse(success: true, data: false);
}

/// Re-send the signup confirmation email to an unconfirmed account.
Future<SupabaseResponse<void>> resendConfirmationEmail(String email) async {
  final res = await AppAuth.instance
      .resendConfirmation(email, redirectTo: dotenv.env['EMAIL_CONFIRM_URL']);
  return res.success
      ? SupabaseResponse(success: true)
      : SupabaseResponse(success: false, error: _mapAuthError(res.error));
}

/// Log in an existing user.
Future<SupabaseResponse<void>> loginUser(String email, String password) async {
  final res = await AppAuth.instance.login(email, password);
  if (!res.success) {
    return SupabaseResponse(success: false, error: _mapAuthError(res.error));
  }
  await PushHelper.ensureRegistered();
  return SupabaseResponse(success: true);
}

/// Log out the current user.
Future<SupabaseResponse<void>> logOut() async {
  try {
    // Mark this as an intentional logout to prevent "unexpected signout" notification
    DebugNotifier.instance.markIntentionalLogout();

    // The row can only be cleared while the session is still valid, and
    // a failure here must not strand the user in a half-logged-out state,
    // so it is best-effort.
    final cleared = await clearPushSubscription();
    if (!cleared.success) {
      debugPrint('Could not clear the push subscription: ${cleared.error}');
    }
    await PushHelper.unregister();
    await PushHelper.dispose();

    // Clear profile picture cache
    await ProfilePictureCache.of(supabase).clear();
    // Clear cached image bytes
    await ImageDiskCache.instance.clear();

    // Revoke server-side + clear the shared session.
    await AppAuth.instance.logout();
    return SupabaseResponse(success: true);
  } catch (error) {
    // Reset the flag if logout fails
    DebugNotifier.instance.resetIntentionalLogout();
    return SupabaseResponse(success: false, error: "Error signing out: $error");
  }
}

/// Permanently delete the current user's account and all their data. On success
/// the local session and caches are cleared, exactly as with a normal logout.
Future<SupabaseResponse<void>> deleteAccount() async {
  try {
    final userId = AppAuth.instance.currentUserId;
    if (userId == null || !AppAuth.instance.isLoggedIn) {
      return SupabaseResponse(success: false, error: "No current user");
    }

    final res = await supabase.rpc("delete_account");
    if (res is Map && res['success'] != true) {
      // Deletion refused, leave everything intact.
      return SupabaseResponse(success: false, error: res['error']?.toString());
    }

    // Account is gone; best-effort remove the profile picture from storage.
    // The JWT is still valid at this point.
    try {
      await supabase.storage.from("profile-pictures").remove([userId]);
    } catch (_) {}

    // Tear down the local session and caches
    await logOut();
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error deleting account: $error");
  }
}

/// Get the username for a given user ID.
Future<SupabaseResponse<krab_user.User>> getUserDetails(String userId) async {
  try {
    final supabase = Supabase.instance.client;

    // Get username
    final usernameResponse =
        await supabase.rpc('get_username', params: {'user_id': userId});
    if (usernameResponse == null || usernameResponse == '') {
      return SupabaseResponse(
          success: false, error: 'Could not get username for this user');
    }

    final username = usernameResponse as String;
    debugPrint("Fetched username for $userId: $username");

    // Cached signed URL
    final pfpUrl = await ProfilePictureCache.of(supabase)
        .getUrl(userId, ttl: const Duration(hours: 1));

    debugPrint("Fetched profile picture URL for $userId: $pfpUrl");

    // Construct user object
    final user = krab_user.User(
      id: userId,
      username: username,
      pfpUrl: pfpUrl ?? '',
    );

    return SupabaseResponse(success: true, data: user);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: 'Error fetching user details: $error',
    );
  }
}

/// Resolve everything an image notification needs in a single RPC call
Future<SupabaseResponse<Map<String, dynamic>>> getImageNotificationContext(
    String imageId) async {
  try {
    final res = await supabase.rpc('get_image_notification',
        params: {'p_image_id': imageId});
    if (res == null || res['success'] != true) {
      return SupabaseResponse(success: false, error: res?['error']?.toString());
    }
    return SupabaseResponse(success: true, data: res as Map<String, dynamic>);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: 'Error fetching image notification: $error');
  }
}

/// Resolve everything a comment notification needs in a single RPC call
Future<SupabaseResponse<Map<String, dynamic>>> getCommentNotificationContext(
    String commentId) async {
  try {
    final res = await supabase
        .rpc('get_comment_notification', params: {'p_comment_id': commentId});
    if (res == null || res['success'] != true) {
      return SupabaseResponse(success: false, error: res?['error']?.toString());
    }
    return SupabaseResponse(success: true, data: res as Map<String, dynamic>);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: 'Error fetching comment notification: $error');
  }
}

/// Edit the username of the current user.
Future<SupabaseResponse<void>> editUsername(String newUsername) async {
  try {
    if (!AppAuth.instance.isLoggedIn) {
      return SupabaseResponse(success: false, error: "No current user");
    }

    await supabase.rpc("edit_username", params: {
      "new_username": newUsername,
    });

    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error updating username: $error",
    );
  }
}

/// Edit the profile picture of the current user.
Future<SupabaseResponse<void>> editProfilePicture(File imageFile) async {
  try {
    final userId = AppAuth.instance.currentUserId;
    if (userId == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }

    // Check if a profile picture already exists
    if (await supabase.storage.from("profile-pictures").exists(userId)) {
      await supabase.storage.from("profile-pictures").update(userId, imageFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
    } else {
      await supabase.storage.from("profile-pictures").upload(userId, imageFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
    }

    await ProfilePictureCache.of(supabase).refresh(userId);
    await evictAvatar(userId);

    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error updating profile picture: $error",
    );
  }
}

/// Get the profile picture of the requested user.
Future<SupabaseResponse<String>> getProfilePictureUrl(String userId) async {
  // Force refresh
  final pfpUrl = await ProfilePictureCache.of(supabase).refresh(userId);

  return SupabaseResponse(
    success: true,
    data: pfpUrl ?? '',
  );
}

/// Delete the profile picture of the current user.
Future<SupabaseResponse<void>> deleteProfilePicture() async {
  try {
    final userId = AppAuth.instance.currentUserId;
    if (userId == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }
    await supabase.storage.from("profile-pictures").remove([userId]);
    await ProfilePictureCache.of(supabase).refresh(userId);
    await evictAvatar(userId);
    return SupabaseResponse(success: true);
  } catch (error) {
    return SupabaseResponse(
      success: false,
      error: "Error deleting profile picture: $error",
    );
  }
}

/// Get the email of the current user.
Future<SupabaseResponse<String>> getEmail() async {
  try {
    final email = AppAuth.instance.currentUserEmail;
    if (email == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }
    return SupabaseResponse(success: true, data: email);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error getting email: $error");
  }
}

/// Change the password of the current user, verifying the current password first.
Future<SupabaseResponse<void>> changePassword(
    String currentPassword, String newPassword) async {
  final res =
      await AppAuth.instance.changePassword(currentPassword, newPassword);
  if (!res.success) {
    return SupabaseResponse(success: false, error: _mapAuthError(res.error));
  }
  return SupabaseResponse(success: true);
}

/// Whether the password reset feature is enabled via the .env configuration.
/// Defaults to enabled.
bool get isPasswordResetEnabled =>
    dotenv.env['ENABLE_PASSWORD_RESET']?.toLowerCase() != 'false';

/// Send a password reset email.
Future<SupabaseResponse<void>> sendPasswordResetEmail(String email) async {
  if (!isPasswordResetEnabled) {
    return SupabaseResponse(success: false, error: 'Password reset is disabled');
  }
  final redirectUrl = dotenv.env['PASSWORD_RESET_URL'] ??
      'https://your-domain.com/reset-password.html';
  final res =
      await AppAuth.instance.sendPasswordReset(email, redirectTo: redirectUrl);
  if (!res.success) {
    return SupabaseResponse(success: false, error: _mapAuthError(res.error));
  }
  return SupabaseResponse(success: true);
}

/// Set setting to receive notifications about new comments under other users' images.
Future<SupabaseResponse<void>> setGroupCommentNotificationSetting(
        bool enabled) =>
    _rpc("set_notify_group_comments",
        params: {"enabled": enabled},
        errorContext: "updating notification setting");

Future<SupabaseResponse<bool>> getGroupCommentNotificationSetting() =>
    _rpc("get_notify_group_comments",
        errorContext: "fetching notification setting",
        parse: (r) => r['enabled'] as bool);

/// Set setting to receive notifications about new reactions on other users' images.
Future<SupabaseResponse<void>> setGroupReactionNotificationSetting(
        bool enabled) =>
    _rpc("set_notify_group_reactions",
        params: {"enabled": enabled},
        errorContext: "updating notification setting");

Future<SupabaseResponse<bool>> getGroupReactionNotificationSetting() =>
    _rpc("get_notify_group_reactions",
        errorContext: "fetching notification setting",
        parse: (r) => r['enabled'] as bool);

/// Resolve the group/reactor names a reaction notification needs.
Future<SupabaseResponse<Map<String, dynamic>>> getReactionNotificationContext(
    String imageId, String reactorId) async {
  try {
    final res = await supabase.rpc('get_reaction_notification', params: {
      'p_image_id': imageId,
      'p_reactor_id': reactorId,
    });
    if (res == null || res['success'] != true) {
      return SupabaseResponse(success: false, error: res?['error']?.toString());
    }
    return SupabaseResponse(success: true, data: res as Map<String, dynamic>);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: 'Error fetching reaction notification: $error');
  }
}
