part of 'krab_api.dart';

/// ------------------ PUSH SUBSCRIPTION & USER FUNCTIONS ------------------

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

extension KrabApiAccount on KrabApi {
  /// Stores the caller's FCM registration token so this instance's backend can
  /// push to it.
  ///
  /// The token identifies this device to FCM. It can be rotated by FCM at any
  /// time, so this is called on every new token. Each instance stores the token
  /// issued for its own sender, so they never overwrite one another.
  Future<SupabaseResponse<void>> saveFcmToken({
    required String token,
    String? username,
  }) async {
    if (!_auth.isLoggedIn) {
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
    if (!_auth.isLoggedIn) {
      return SupabaseResponse(success: false, error: errorNotLoggedIn);
    }

    try {
      await _client.from('Users').update({
        'push_fcm_token': null,
      }).eq('id', _auth.currentUserId!);
      return SupabaseResponse(success: true);
    } catch (error) {
      return _failure(error, "clearing the push token");
    }
  }

  /// Fetches this instance's public settings and caches them against the
  /// instance, once a backend is known and before login.
  Future<SupabaseResponse<void>> fetchInstanceConfig() async {
    try {
      final res = await _client.functions.invoke('instance-config');

      final body = res.data;
      if (body is! Map) {
        debugPrint('InstanceConfig[$instanceId]: unexpected body: $body');
        return SupabaseResponse(success: false, error: errorServer);
      }

      final config = InstanceConfig.fromEdgeFunction(body);
      await instance.updateConfig(config);

      debugPrint('InstanceConfig[$instanceId]: fetched $config');
      return SupabaseResponse(success: true);
    } catch (error) {
      debugPrint('InstanceConfig[$instanceId]: fetch failed: $error');
      return _failure(error, "fetching the instance configuration");
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
    final res = await _auth.register(email, password,
        username: username, redirectTo: instance.config.emailConfirmRedirect);
    if (!res.success) {
      return SupabaseResponse(success: false, error: _mapAuthError(res.error));
    }
    if (_auth.isLoggedIn) {
      await PushHelper.ensureRegistered(instance);
      return SupabaseResponse(success: true, data: true);
    }
    // Verification required
    return SupabaseResponse(success: true, data: false);
  }

  /// Re-send the signup confirmation email to an unconfirmed account.
  Future<SupabaseResponse<void>> resendConfirmationEmail(String email) async {
    final res = await _auth.resendConfirmation(email,
        redirectTo: instance.config.emailConfirmRedirect);
    return res.success
        ? SupabaseResponse(success: true)
        : SupabaseResponse(success: false, error: _mapAuthError(res.error));
  }

  /// Log in an existing user.
  Future<SupabaseResponse<void>> loginUser(
      String email, String password) async {
    final res = await _auth.login(email, password);
    if (!res.success) {
      return SupabaseResponse(success: false, error: _mapAuthError(res.error));
    }
    await PushHelper.ensureRegistered(instance);
    return SupabaseResponse(success: true);
  }

  /// Log out the current user of this instance.
  Future<SupabaseResponse<void>> logOut() async {
    try {
      DebugNotifier.instance.markIntentionalLogout();

      // The row can only be cleared while the session is still valid, and
      // a failure here must not strand the user in a half-logged-out state,
      // so it is best-effort.
      final cleared = await clearFcmToken();
      if (!cleared.success) {
        debugPrint('Could not clear the push token: ${cleared.error}');
      }
      await PushHelper.unregister(instance);

      // Only this instance's caches
      await instance.clearCaches();

      // Revoke server-side and clear this instance's session.
      await _auth.logout();
      return SupabaseResponse(success: true);
    } catch (error) {
      // Reset the flag if logout fails
      DebugNotifier.instance.resetIntentionalLogout();
      return _failure(error, "signing out");
    }
  }

  /// Permanently delete the current user's account and all their data. On
  /// success the local session and caches are cleared, exactly as with a normal
  /// logout.
  Future<SupabaseResponse<void>> deleteAccount() async {
    try {
      final userId = _auth.currentUserId;
      if (userId == null || !_auth.isLoggedIn) {
        return SupabaseResponse(success: false, error: errorNotLoggedIn);
      }

      final res = await _client.rpc("delete_account");
      if (res is Map && res['success'] != true) {
        // Deletion refused, leave everything intact.
        return SupabaseResponse(
            success: false, error: res['error']?.toString());
      }

      // Account is gone; best-effort remove the profile picture from storage.
      // The JWT is still valid at this point.
      try {
        await _client.storage.from("profile-pictures").remove([userId]);
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
          await _client.rpc('get_username', params: {'user_id': userId});
      if (username == null || username == '') {
        return SupabaseResponse(success: false, error: errorServer);
      }

      final pfpUrl =
          await _pictures.getUrl(userId, ttl: const Duration(hours: 1));

      return SupabaseResponse(
        success: true,
        data: krab_user.User(
          instanceId: instanceId,
          id: userId,
          username: username as String,
          pfpUrl: pfpUrl ?? '',
        ),
      );
    } catch (error) {
      return _failure(error, 'fetching user details');
    }
  }

  /// The signed-in user of this instance, or null when there isn't one.
  Future<SupabaseResponse<krab_user.User>> getCurrentUser() async {
    final userId = _auth.currentUserId;
    if (userId == null) {
      return SupabaseResponse(success: false, error: errorNotLoggedIn);
    }
    return getUserDetails(userId);
  }

  /// Resolve everything one notification needs.
  Future<SupabaseResponse<Map<String, dynamic>>> _notificationContext(
      String fn, Map<String, dynamic> params, String what) async {
    try {
      final res = await _client.rpc(fn, params: params);
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
    if (!_auth.isLoggedIn) {
      return SupabaseResponse(success: false, error: errorNotLoggedIn);
    }
    return _rpc("edit_username",
        params: {"new_username": newUsername},
        errorContext: "updating username");
  }

  /// Edit the profile picture of the current user.
  Future<SupabaseResponse<void>> editProfilePicture(File imageFile) async {
    try {
      final userId = _auth.currentUserId;
      if (userId == null) {
        return SupabaseResponse(success: false, error: errorNotLoggedIn);
      }

      // Check if a profile picture already exists
      if (await _client.storage.from("profile-pictures").exists(userId)) {
        await _client.storage.from("profile-pictures").update(userId, imageFile,
            fileOptions: const FileOptions(contentType: 'image/jpeg'));
      } else {
        await _client.storage.from("profile-pictures").upload(userId, imageFile,
            fileOptions: const FileOptions(contentType: 'image/jpeg'));
      }

      await _pictures.refresh(userId);
      await evictAvatar(instanceId, userId);

      return SupabaseResponse(success: true);
    } catch (error) {
      return _failure(error, "updating the profile picture");
    }
  }

  /// Get the profile picture of the requested user.
  Future<SupabaseResponse<String>> getProfilePictureUrl(String userId) async {
    // Force refresh
    final pfpUrl = await _pictures.refresh(userId);

    return SupabaseResponse(
      success: true,
      data: pfpUrl ?? '',
    );
  }

  /// Delete the profile picture of the current user.
  Future<SupabaseResponse<void>> deleteProfilePicture() async {
    try {
      final userId = _auth.currentUserId;
      if (userId == null) {
        return SupabaseResponse(success: false, error: errorNotLoggedIn);
      }
      await _client.storage.from("profile-pictures").remove([userId]);
      await _pictures.refresh(userId);
      await evictAvatar(instanceId, userId);
      return SupabaseResponse(success: true);
    } catch (error) {
      return _failure(error, "deleting the profile picture");
    }
  }

  /// Get the email of the current user.
  Future<SupabaseResponse<String>> getEmail() async {
    try {
      final email = _auth.currentUserEmail;
      if (email == null) {
        return SupabaseResponse(success: false, error: errorNotLoggedIn);
      }
      return SupabaseResponse(success: true, data: email);
    } catch (error) {
      return _failure(error, "getting the email");
    }
  }

  /// Change the password of the current user, verifying the current password
  /// first.
  Future<SupabaseResponse<void>> changePassword(
      String currentPassword, String newPassword) async {
    final res = await _auth.changePassword(currentPassword, newPassword);
    if (!res.success) {
      return SupabaseResponse(success: false, error: _mapAuthError(res.error));
    }
    return SupabaseResponse(success: true);
  }

  /// Whether this instance has a password-reset page.
  bool get isPasswordResetEnabled => instance.config.hasPasswordReset;

  /// Send a password reset email.
  Future<SupabaseResponse<void>> sendPasswordResetEmail(String email) async {
    if (!isPasswordResetEnabled) {
      return SupabaseResponse(success: false, error: errorServer);
    }
    final res = await _auth.sendPasswordReset(
      email,
      redirectTo: instance.config.passwordResetUrl,
    );
    if (!res.success) {
      return SupabaseResponse(success: false, error: _mapAuthError(res.error));
    }
    return SupabaseResponse(success: true);
  }

  /// Set setting to receive notifications about new comments under other users'
  /// images.
  Future<SupabaseResponse<void>> setGroupCommentNotificationSetting(
          bool enabled) =>
      _rpc("set_notify_group_comments",
          params: {"enabled": enabled},
          errorContext: "updating notification setting");

  Future<SupabaseResponse<bool>> getGroupCommentNotificationSetting() =>
      _rpc("get_notify_group_comments",
          errorContext: "fetching notification setting",
          parse: (r) => r['enabled'] as bool);

  /// Set setting to receive notifications about new reactions on other users'
  /// images.
  Future<SupabaseResponse<void>> setGroupReactionNotificationSetting(
          bool enabled) =>
      _rpc("set_notify_group_reactions",
          params: {"enabled": enabled},
          errorContext: "updating notification setting");

  Future<SupabaseResponse<bool>> getGroupReactionNotificationSetting() =>
      _rpc("get_notify_group_reactions",
          errorContext: "fetching notification setting",
          parse: (r) => r['enabled'] as bool);
}
