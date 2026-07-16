part of 'supabase.dart';

/// ------------------ PUSH SUBSCRIPTION & USER FUNCTIONS ------------------

/// Stores the caller's FCM registration token so the backend can push to it.
///
/// The token identifies this device to FCM. It can be rotated by FCM at any
/// time, so this is called on every new token.
Future<SupabaseResponse<void>> saveFcmToken({
  required String token,
  String? username,
}) async {
  if (!AppAuth.instance.isLoggedIn) {
    return SupabaseResponse(success: false, error: errorNotLoggedIn);
  }
  return _rpc("register_fcm_token",
      params: {
        "p_token": token,
        if (username != null) "p_username": username,
      },
      errorContext: "saving push token");
}

/// Drops the caller's FCM token, so the backend stops pushing to a device the
/// user has signed out of.
Future<SupabaseResponse<void>> clearFcmToken() async {
  if (!AppAuth.instance.isLoggedIn) {
    return SupabaseResponse(success: false, error: errorNotLoggedIn);
  }

  try {
    await supabase.from('Users').update({
      'push_fcm_token': null,
    }).eq('id', AppAuth.instance.currentUserId!);
    return SupabaseResponse(success: true);
  } catch (error) {
    return _failure(error, "clearing the push token");
  }
}

/// Fetches this instance's public settings and caches them, once a backend is
/// known and before login.
Future<SupabaseResponse<void>> fetchInstanceConfig() async {
  try {
    final res = await supabase.functions.invoke('instance-config');

    final body = res.data;
    if (body is! Map) {
      debugPrint('InstanceConfig: unexpected response body: $body');
      return SupabaseResponse(success: false, error: errorServer);
    }

    String field(String key) => (body[key] as String?) ?? '';

    final fcm = body['fcm'];
    String fcmField(String key) =>
        (fcm is Map ? fcm[key] as String? : null) ?? '';

    final fcmAppId = fcmField('app_id');
    final fcmApiKey = fcmField('api_key');
    final fcmSenderId = fcmField('sender_id');
    final fcmProjectId = fcmField('project_id');
    final resetUrl = field('password_reset_url');
    final confirmUrl = field('email_confirm_url');

    await UserPreferences.setInstanceConfig(
      fcmAppId: fcmAppId,
      fcmApiKey: fcmApiKey,
      fcmSenderId: fcmSenderId,
      fcmProjectId: fcmProjectId,
      resetUrl: resetUrl,
      confirmUrl: confirmUrl,
    );

    debugPrint('InstanceConfig: fetched '
        '(fcm=${fcmAppId.isNotEmpty}, '
        'passwordReset=${resetUrl.isNotEmpty}, '
        'emailConfirm=${confirmUrl.isNotEmpty})');
    return SupabaseResponse(success: true);
  } catch (error) {
    debugPrint('InstanceConfig: fetch failed: $error');
    return _failure(error, "fetching the instance configuration");
  }
}

/// Where GoTrue sends the user after they confirm their email. Null when this
/// instance has no confirmation page, in which case GoTrue falls back to its
/// own SITE_URL.
String? get _emailConfirmUrl => UserPreferences.emailConfirmUrl.isEmpty
    ? null
    : UserPreferences.emailConfirmUrl;

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
  // After confirming, GoTrue redirects here. When this instance has no
  // confirmation page it falls back to the server's SITE_URL.
  final res = await AppAuth.instance.register(email, password,
      username: username, redirectTo: _emailConfirmUrl);
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
      .resendConfirmation(email, redirectTo: _emailConfirmUrl);
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
    final cleared = await clearFcmToken();
    if (!cleared.success) {
      debugPrint('Could not clear the push token: ${cleared.error}');
    }
    await PushHelper.unregister();
    await PushHelper.dispose();

    // Clear caches
    await ProfilePictureCache.of(supabase).clear();
    await ImageDiskCache.instance.clear();
    clearReactionCache();
    clearViewerCaches();

    // Revoke server-side + clear the shared session.
    await AppAuth.instance.logout();
    return SupabaseResponse(success: true);
  } catch (error) {
    // Reset the flag if logout fails
    DebugNotifier.instance.resetIntentionalLogout();
    return _failure(error, "signing out");
  }
}

/// Permanently delete the current user's account and all their data. On success
/// the local session and caches are cleared, exactly as with a normal logout.
Future<SupabaseResponse<void>> deleteAccount() async {
  try {
    final userId = AppAuth.instance.currentUserId;
    if (userId == null || !AppAuth.instance.isLoggedIn) {
      return SupabaseResponse(success: false, error: errorNotLoggedIn);
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
    return _failure(error, "deleting the account");
  }
}

/// Get the username and profile picture for a given user ID.
Future<SupabaseResponse<krab_user.User>> getUserDetails(String userId) async {
  try {
    final username =
        await supabase.rpc('get_username', params: {'user_id': userId});
    if (username == null || username == '') {
      return SupabaseResponse(success: false, error: errorServer);
    }

    final pfpUrl = await ProfilePictureCache.of(supabase)
        .getUrl(userId, ttl: const Duration(hours: 1));

    return SupabaseResponse(
      success: true,
      data: krab_user.User(
        id: userId,
        username: username as String,
        pfpUrl: pfpUrl ?? '',
      ),
    );
  } catch (error) {
    return _failure(error, 'fetching user details');
  }
}

/// Resolve everything one notification needs.
Future<SupabaseResponse<Map<String, dynamic>>> _notificationContext(
    String fn, Map<String, dynamic> params, String what) async {
  try {
    final res = await supabase.rpc(fn, params: params);
    if (res == null || res['success'] != true) {
      return SupabaseResponse(
          success: false, error: res?['error']?.toString() ?? errorServer);
    }
    return SupabaseResponse(success: true, data: res as Map<String, dynamic>);
  } catch (error) {
    return _failure(error, 'fetching the $what notification');
  }
}

Future<SupabaseResponse<Map<String, dynamic>>> getImageNotificationContext(
        String imageId) =>
    _notificationContext(
        'get_image_notification', {'p_image_id': imageId}, 'image');

Future<SupabaseResponse<Map<String, dynamic>>> getCommentNotificationContext(
        String commentId) =>
    _notificationContext(
        'get_comment_notification', {'p_comment_id': commentId}, 'comment');

Future<SupabaseResponse<Map<String, dynamic>>> getReactionNotificationContext(
        String imageId, String reactorId) =>
    _notificationContext('get_reaction_notification',
        {'p_image_id': imageId, 'p_reactor_id': reactorId}, 'reaction');

/// Edit the username of the current user.
Future<SupabaseResponse<void>> editUsername(String newUsername) async {
  if (!AppAuth.instance.isLoggedIn) {
    return SupabaseResponse(success: false, error: errorNotLoggedIn);
  }
  return _rpc("edit_username",
      params: {"new_username": newUsername}, errorContext: "updating username");
}

/// Edit the profile picture of the current user.
Future<SupabaseResponse<void>> editProfilePicture(File imageFile) async {
  try {
    final userId = AppAuth.instance.currentUserId;
    if (userId == null) {
      return SupabaseResponse(success: false, error: errorNotLoggedIn);
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
    return _failure(error, "updating the profile picture");
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
      return SupabaseResponse(success: false, error: errorNotLoggedIn);
    }
    await supabase.storage.from("profile-pictures").remove([userId]);
    await ProfilePictureCache.of(supabase).refresh(userId);
    await evictAvatar(userId);
    return SupabaseResponse(success: true);
  } catch (error) {
    return _failure(error, "deleting the profile picture");
  }
}

/// Get the email of the current user.
Future<SupabaseResponse<String>> getEmail() async {
  try {
    final email = AppAuth.instance.currentUserEmail;
    if (email == null) {
      return SupabaseResponse(success: false, error: errorNotLoggedIn);
    }
    return SupabaseResponse(success: true, data: email);
  } catch (error) {
    return _failure(error, "getting the email");
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

/// Whether this instance has a password-reset page.
bool get isPasswordResetEnabled => UserPreferences.passwordResetUrl.isNotEmpty;

/// Send a password reset email.
Future<SupabaseResponse<void>> sendPasswordResetEmail(String email) async {
  if (!isPasswordResetEnabled) {
    return SupabaseResponse(success: false, error: errorServer);
  }
  final res = await AppAuth.instance.sendPasswordReset(
    email,
    redirectTo: UserPreferences.passwordResetUrl,
  );
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
