import 'package:flutter/material.dart';
import 'package:krab/l10n/app_localizations.dart';
import 'package:krab/services/api/krab_api.dart';

export 'package:krab/l10n/app_localizations.dart';

/// Render a [SupabaseResponse.error] as something to show a person.
///
/// The codes KRAB raises itself are translated. Anything else is a message the
/// server wrote and is shown as it came: an instance knows things the app does
/// not, so its refusals are worth reading even though they arrive only in the
/// server's own language.
String describeError(AppLocalizations l10n, String? error) {
  switch (error) {
    case null:
      return l10n.unknown_error;
    case errorNetwork:
      return l10n.error_network;
    case errorServer:
      return l10n.error_server;
    case errorNotLoggedIn:
      return l10n.error_not_logged_in;
    case errorImageTooLarge:
      return l10n.error_image_too_large(maxImageUploadBytes ~/ (1024 * 1024));
    case errorNameTooShort:
      return l10n.error_name_too_short;
    case errorInvalidCredentials:
      return l10n.invalid_email_or_password;
    case errorEmailExists:
      return l10n.email_already_exists;
    case errorPasswordTooWeak:
      return l10n.password_too_weak;
    case errorEmailNotConfirmed:
      return l10n.email_not_confirmed;
    case errorAuth:
      return l10n.error_server;
    default:
      return error;
  }
}

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  /// [describeError] for the common case. Inside an async callback, capture
  /// `context.l10n` before the await and call [describeError] directly.
  String errorText(String? error) => describeError(l10n, error);
}
