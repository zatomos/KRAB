import 'package:flutter/material.dart';
import 'package:krab/l10n/app_localizations.dart';

export 'package:krab/l10n/app_localizations.dart';

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  /// Returns error when non-null, otherwise a localized "unknown error"
  /// fallback. Use for API error messages that may be null.
  String errorOr(String? error) => error ?? l10n.unknown_error;
}
