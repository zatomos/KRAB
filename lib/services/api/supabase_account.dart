part of 'supabase.dart';

/// ------------------ FCM TOKEN & USER FUNCTIONS ------------------

/// Handles FCM token registration.
Future<SupabaseResponse<void>> fcmTokenHandler({String? username}) async {
  try {
    await FirebaseMessaging.instance.requestPermission();

    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken == null) {
      return SupabaseResponse(success: false, error: "Error getting FCM token");
    }

    if (supabase.auth.currentUser == null) {
      return SupabaseResponse(success: false, error: "No authenticated user");
    }

    final response = await supabase.rpc("register_fcm_token", params: {
      "p_fcm_token": fcmToken,
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
      error: "Error handling FCM token: $error",
    );
  }
}

String _authError(AuthException e) {
  switch (e.code) {
    case 'invalid_credentials':
      return 'invalid_email_or_password';
    case 'user_already_exists':
    case 'email_exists':
      return 'email_already_exists';
    case 'weak_password':
      return 'password_too_weak';
    default:
      return e.message;
  }
}

/// Register a new user.
Future<SupabaseResponse<void>> registerUser(
    String username, String email, String password) async {
  debugPrint("Registering user: $username, $email");
  try {
    final authResponse =
        await supabase.auth.signUp(email: email, password: password);

    if (authResponse.user == null) {
      return SupabaseResponse(
          success: false, error: "No user returned during sign up");
    }

    // Sign in the user
    final signInResponse = await supabase.auth
        .signInWithPassword(email: email, password: password);

    if (signInResponse.user == null) {
      return SupabaseResponse(
          success: false, error: "Failed to sign in after sign up");
    }

    // Mint the independent background session so they never rotate the
    // interactive session's token
    await BackgroundSession.mintAndStore(email, password);

    // Handle FCM token registration
    await fcmTokenHandler(username: username);

    return SupabaseResponse(success: true);
  } catch (error) {
    final message = error is AuthException
        ? _authError(error)
        : 'Error registering user: $error';
    return SupabaseResponse(success: false, error: message);
  }
}

/// Log in an existing user.
Future<SupabaseResponse<void>> loginUser(String email, String password) async {
  try {
    final authResponse = await supabase.auth
        .signInWithPassword(email: email, password: password);
    if (authResponse.user == null) {
      return SupabaseResponse(
          success: false, error: "No user returned during login");
    }
    // Mint the independent background session so they never rotate the
    // interactive session's token
    await BackgroundSession.mintAndStore(email, password);
    await fcmTokenHandler();
    return SupabaseResponse(success: true);
  } catch (error) {
    final message =
        error is AuthException ? _authError(error) : 'Error logging in: $error';
    return SupabaseResponse(success: false, error: message);
  }
}

/// Log out the current user.
Future<SupabaseResponse<void>> logOut() async {
  try {
    // Mark this as an intentional logout to prevent "unexpected signout" notification
    DebugNotifier.instance.markIntentionalLogout();

    // Clean up FCM listeners
    await FcmHelper.dispose();

    // Clear the independent background session
    await BackgroundSession.clear();

    // Clear profile picture cache
    await ProfilePictureCache.of(supabase).clear();
    // Clear cached image bytes
    await ImageDiskCache.instance.clear();

    // Sign out
    await supabase.auth.signOut();
    return SupabaseResponse(success: true);
  } catch (error) {
    // Reset the flag if logout fails
    DebugNotifier.instance.resetIntentionalLogout();
    return SupabaseResponse(success: false, error: "Error signing out: $error");
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
    String imageId, String groupId) async {
  try {
    final res = await supabase.rpc('get_image_notification',
        params: {'p_image_id': imageId, 'p_group_id': groupId});
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
    final user = supabase.auth.currentUser;
    if (user == null) {
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
    final user = supabase.auth.currentUser;
    if (user == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }

    // Check if a profile picture already exists
    if (await supabase.storage.from("profile-pictures").exists(user.id)) {
      await supabase.storage.from("profile-pictures").update(user.id, imageFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
    } else {
      await supabase.storage.from("profile-pictures").upload(user.id, imageFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
    }

    await ProfilePictureCache.of(supabase).refresh(user.id);
    await evictAvatar(user.id);

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
    final user = supabase.auth.currentUser;
    if (user == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }
    await supabase.storage.from("profile-pictures").remove([user.id]);
    await ProfilePictureCache.of(supabase).refresh(user.id);
    await evictAvatar(user.id);
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
    final user = supabase.auth.currentUser;
    if (user == null) {
      return SupabaseResponse(success: false, error: "No current user");
    }
    return SupabaseResponse(success: true, data: user.email);
  } catch (error) {
    return SupabaseResponse(
        success: false, error: "Error getting email: $error");
  }
}

/// Change the password of the current user, verifying the current password first.
Future<SupabaseResponse<void>> changePassword(
    String currentPassword, String newPassword) async {
  try {
    final email = supabase.auth.currentUser?.email;
    if (email == null) {
      return SupabaseResponse(success: false, error: 'No authenticated user.');
    }
    await supabase.auth
        .signInWithPassword(email: email, password: currentPassword);
    await supabase.auth.updateUser(UserAttributes(password: newPassword));
    // Revoke the old background sessions server-side, then re-mint with the new
    // password so no stale background tokens linger after a password change.
    await BackgroundSession.clear();
    await BackgroundSession.mintAndStore(email, newPassword);
    return SupabaseResponse(success: true);
  } catch (error) {
    final message = error is AuthException
        ? _authError(error)
        : 'Error changing password: $error';
    return SupabaseResponse(success: false, error: message);
  }
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
  try {
    final redirectUrl = dotenv.env['PASSWORD_RESET_URL'] ??
        'https://your-domain.com/reset-password.html';
    await supabase.auth.resetPasswordForEmail(email, redirectTo: redirectUrl);
    return SupabaseResponse(success: true);
  } catch (error) {
    final message = error is AuthException
        ? _authError(error)
        : 'Error sending password reset email: $error';
    return SupabaseResponse(success: false, error: message);
  }
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
