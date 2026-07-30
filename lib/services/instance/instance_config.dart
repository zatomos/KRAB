/// The public settings a KRAB backend publishes about itself, fetched from its
/// `instance-config` edge function and cached alongside the instance.
///
/// None of these are secret: the FCM values are the same four fields any client
/// of that Firebase project holds, and the two URLs are public pages.
class InstanceConfig {
  const InstanceConfig({
    this.fcmAppId = '',
    this.fcmApiKey = '',
    this.fcmSenderId = '',
    this.fcmProjectId = '',
    this.passwordResetUrl = '',
    this.emailConfirmUrl = '',
  });

  /// What an instance looks like before its config has been fetched.
  static const InstanceConfig empty = InstanceConfig();

  final String fcmAppId;
  final String fcmApiKey;
  final String fcmSenderId;
  final String fcmProjectId;
  final String passwordResetUrl;
  final String emailConfirmUrl;

  /// True once this instance's FCM config is known, so Firebase can be brought
  /// up for it.
  bool get hasFcm =>
      fcmAppId.isNotEmpty &&
      fcmApiKey.isNotEmpty &&
      fcmSenderId.isNotEmpty &&
      fcmProjectId.isNotEmpty;

  /// Whether this instance hosts a password-reset page.
  bool get hasPasswordReset => passwordResetUrl.isNotEmpty;

  /// Where GoTrue sends the user after they confirm their email. Null when this
  /// instance has no confirmation page, in which case GoTrue falls back to its
  /// own SITE_URL.
  String? get emailConfirmRedirect =>
      emailConfirmUrl.isEmpty ? null : emailConfirmUrl;

  Map<String, dynamic> toJson() => {
        'fcm_app_id': fcmAppId,
        'fcm_api_key': fcmApiKey,
        'fcm_sender_id': fcmSenderId,
        'fcm_project_id': fcmProjectId,
        'password_reset_url': passwordResetUrl,
        'email_confirm_url': emailConfirmUrl,
      };

  factory InstanceConfig.fromJson(Map<String, dynamic> json) {
    String field(String key) => (json[key] as String?) ?? '';
    return InstanceConfig(
      fcmAppId: field('fcm_app_id'),
      fcmApiKey: field('fcm_api_key'),
      fcmSenderId: field('fcm_sender_id'),
      fcmProjectId: field('fcm_project_id'),
      passwordResetUrl: field('password_reset_url'),
      emailConfirmUrl: field('email_confirm_url'),
    );
  }

  /// Reads the shape the `instance-config` edge function returns, which nests
  /// the FCM fields under `fcm` and uses its own key names.
  factory InstanceConfig.fromEdgeFunction(Map<dynamic, dynamic> body) {
    String field(String key) => (body[key] as String?) ?? '';
    final fcm = body['fcm'];
    String fcmField(String key) =>
        (fcm is Map ? fcm[key] as String? : null) ?? '';

    return InstanceConfig(
      fcmAppId: fcmField('app_id'),
      fcmApiKey: fcmField('api_key'),
      fcmSenderId: fcmField('sender_id'),
      fcmProjectId: fcmField('project_id'),
      passwordResetUrl: field('password_reset_url'),
      emailConfirmUrl: field('email_confirm_url'),
    );
  }

  @override
  String toString() => 'InstanceConfig{fcm: $hasFcm, '
      'passwordReset: $hasPasswordReset, '
      'emailConfirm: ${emailConfirmUrl.isNotEmpty}}';
}
