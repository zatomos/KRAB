import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/soft_button.dart';

class ImageSentDialog extends StatelessWidget {
  final bool success;
  final String? errorMsg;

  const ImageSentDialog({super.key, required this.success, this.errorMsg});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(success
          ? context.l10n.image_sent_title
          : context.l10n.error_image_not_sent_title),
      content: Text(success
          ? context.l10n.image_sent_subtitle
          : context.l10n
              .error_image_not_sent_subtitle(errorMsg ?? 'Unknown error')),
      actions: [
        SoftButton(
            onPressed: () => Navigator.of(context).pop(),
            label: "OK",
            color: GlobalThemeData.darkColorScheme.primary),
      ],
    );
  }
}
