import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/soft_button.dart';

/// The action the user chose.
enum AvatarAction { edit, delete }

/// Shows an add/edit/delete chooser for an avatar-style image and resolves
/// to the chosen AvatarAction, or `null` if the user cancelled.
/// The caller is responsible for picking, uploading or deleting the image.
///
/// When hasImage is false the primary button is an "add" action and the
/// delete button is hidden.
Future<AvatarAction?> showEditAvatarDialog(
  BuildContext context, {
  required String title,
  required bool hasImage,
}) {
  return showDialog<AvatarAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          label: dialogContext.l10n.cancel,
          color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
        ),
        SoftButton(
          onPressed: () => Navigator.of(dialogContext).pop(AvatarAction.edit),
          label: hasImage ? dialogContext.l10n.edit : dialogContext.l10n.add,
          icon: hasImage ? Icons.edit : Icons.add,
          color: GlobalThemeData.darkColorScheme.primary,
        ),
        if (hasImage)
          SoftButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(AvatarAction.delete),
            label: dialogContext.l10n.delete,
            icon: Icons.delete_forever,
            color: GlobalThemeData.darkColorScheme.error,
          ),
      ],
    ),
  );
}
