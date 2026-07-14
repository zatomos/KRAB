import 'dart:io';

import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/image_crop_helper.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/soft_button.dart';

/// The action the user chose.
enum AvatarAction { edit, delete }

class AvatarTarget {
  /// Whether there is already an image.
  final bool hasImage;

  final String dialogTitle;
  final Future<SupabaseResponse<void>> Function(File image) upload;
  final Future<SupabaseResponse<void>> Function() remove;

  /// A signed URL for the image now in storage, read back after an upload.
  final Future<SupabaseResponse<String>> Function() freshUrl;

  final String Function(String error) uploadFailed;
  final String Function(String error) removeFailed;
  final String uploadSucceeded;
  final String removeSucceeded;

  const AvatarTarget({
    required this.hasImage,
    required this.dialogTitle,
    required this.upload,
    required this.remove,
    required this.freshUrl,
    required this.uploadFailed,
    required this.removeFailed,
    required this.uploadSucceeded,
    required this.removeSucceeded,
  });
}

/// What an edit left behind: the avatar's new URL, or null once deleted.
class AvatarChange {
  final String? url;
  const AvatarChange(this.url);
}

/// Ask what to do with an avatar, then do it:.
/// Returns null when nothing changed, whether the user cancelled or it failed.
Future<AvatarChange?> editAvatar(
  BuildContext context,
  AvatarTarget target,
) async {
  final l10n = context.l10n;
  final action = await showEditAvatarDialog(
    context,
    title: target.dialogTitle,
    hasImage: target.hasImage,
  );
  if (action == null) return null;

  if (action == AvatarAction.delete) {
    final res = await target.remove();
    if (!res.success) {
      showSnackBar(target.removeFailed(describeError(l10n, res.error)),
          tone: SnackTone.failure);
      return null;
    }
    showSnackBar(target.removeSucceeded, tone: SnackTone.success);
    return const AvatarChange(null);
  }

  final image = await pickAndCropSquareImage(toolbarTitle: l10n.crop_image);
  if (image == null) return null;

  final res = await target.upload(image);
  if (!res.success) {
    showSnackBar(target.uploadFailed(describeError(l10n, res.error)),
        tone: SnackTone.failure);
    return null;
  }

  // The image is up, so the avatar has changed whether or not we can read its
  // URL back.
  final url = await target.freshUrl();
  showSnackBar(target.uploadSucceeded, tone: SnackTone.success);
  return AvatarChange(url.success ? url.data : null);
}

/// Shows an add/edit/delete chooser for an avatar-style image and resolves
/// to the chosen AvatarAction, or `null` if the user cancelled.
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
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        SoftButton(
          onPressed: () => Navigator.of(dialogContext).pop(AvatarAction.edit),
          label: hasImage ? dialogContext.l10n.edit : dialogContext.l10n.add,
          icon: hasImage ? Icons.edit : Icons.add,
          color: Theme.of(context).colorScheme.primary,
        ),
        if (hasImage)
          SoftButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(AvatarAction.delete),
            label: dialogContext.l10n.delete,
            icon: Icons.delete_forever,
            color: Theme.of(context).colorScheme.error,
          ),
      ],
    ),
  );
}
