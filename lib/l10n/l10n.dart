import 'package:flutter/material.dart';
import 'package:krab/l10n/app_localizations.dart';
import 'package:krab/services/api/supabase.dart';

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
    case errorPhotoTooLarge:
      return l10n.error_photo_too_large(maxImageUploadBytes ~/ (1024 * 1024));
    case errorNameTooShort:
      return l10n.error_name_too_short;
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
