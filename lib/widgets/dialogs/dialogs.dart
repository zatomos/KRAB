import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/soft_button.dart';

/// Shows a cancel/confirm dialog and resolves to true only if the user
/// confirms.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  String? cancelLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message != null ? Text(message) : null,
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(context).pop(false),
          label: cancelLabel ?? context.l10n.cancel,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        SoftButton(
          onPressed: () => Navigator.of(context).pop(true),
          label: confirmLabel,
          color: destructive
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
      ],
    ),
  );
  return result ?? false;
}
