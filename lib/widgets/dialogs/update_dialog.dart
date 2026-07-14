import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/soft_button.dart';

Future<void> showUpdateDialog({
  required BuildContext context,
  required UpdateService updateService,
  required UpdateInfo info,
  String? currentVersion,
}) async {
  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      bool isDownloading = false;
      double progress = 0.0;

      return StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.system_update_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.update_available,
                  overflow: TextOverflow.visible,
                  softWrap: true,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.version(info.version),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (currentVersion != null)
                Text(
                  context.l10n.current_version(currentVersion),
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                ),
              const SizedBox(height: 12),
              Text(
                context.l10n.whats_new,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (info.releases.any((r) => r.changelog.isNotEmpty)) ...[
                const SizedBox(height: 4),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final release in info.releases)
                              if (release.changelog.isNotEmpty) ...[
                                // Only label versions when several are shown
                                if (info.releases
                                        .where((r) => r.changelog.isNotEmpty)
                                        .length >
                                    1)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        top: 8, bottom: 2),
                                    child: Text(
                                      context.l10n.version(release.version),
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ...release.changelog.map(
                                  (change) => Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('• ',
                                          style: TextStyle(fontSize: 14)),
                                      Expanded(
                                        child: Text(change,
                                            style:
                                                const TextStyle(fontSize: 14)),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ] else ...[
                Text(
                  context.l10n.no_changelog,
                  style: const TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey,
                  ),
                ),
              ],
              if (isDownloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceBright,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.downloading((progress * 100).toStringAsFixed(0)),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
          actionsOverflowButtonSpacing:
              GlobalThemeData.dialogActionsOverflowSpacing,
          actions: [
            if (!isDownloading)
              SoftButton(
                onPressed: () => Navigator.pop(context),
                label: context.l10n.later,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            isDownloading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : SoftButton(
                    onPressed: () async {
                      setDialogState(() {
                        isDownloading = true;
                        progress = 0.0;
                      });

                      final success = await updateService.downloadAndInstall(
                        info.downloadUrl,
                        (p) => setDialogState(() => progress = p),
                      );

                      if (success) {
                        if (context.mounted) {
                          Navigator.pop(context);
                          showSnackBar(
                            context.l10n.installing_update,
                            tone: SnackTone.warning,
                          );
                        }
                      } else {
                        setDialogState(() => isDownloading = false);
                        if (context.mounted) {
                          showSnackBar(
                            context.l10n.update_failed,
                            tone: SnackTone.failure,
                          );
                        }
                      }
                    },
                    label: context.l10n.update_now,
                    color: Theme.of(context).colorScheme.primary,
                  ),
          ],
        ),
      );
    },
  );
}
