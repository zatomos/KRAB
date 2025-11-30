import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/SoftButton.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/themes/GlobalThemeData.dart';

class UpdateChecker extends StatefulWidget {
  final Widget child;

  const UpdateChecker({
    super.key,
    required this.child,
  });

  @override
  State<UpdateChecker> createState() => _UpdateCheckerState();
}

class _UpdateCheckerState extends State<UpdateChecker> {
  final _updateService = UpdateService();
  String? _currentVersion;

  @override
  void initState() {
    super.initState();
    _loadCurrentVersion();
    Future.delayed(const Duration(seconds: 2), _checkForUpdates);
  }

  Future<void> _loadCurrentVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() => _currentVersion = info.version);
  }

  Future<void> _checkForUpdates() async {
    if (!_updateService.isEnabled) {
      debugPrint('Auto-update disabled');
      return;
    }

    final result = await _updateService.checkForUpdate();

    if (!result.success && mounted) {
      showSnackBar(
        context,
        'Failed to check for updates.',
        color: Colors.orangeAccent,
      );
      return;
    }

    if (result.hasUpdate && result.info != null && mounted) {
      _showUpdateDialog(result.info!);
    } else {
      debugPrint('No update available');
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog(
      context: context,
      barrierDismissible: !info.forceUpdate,
      builder: (context) {
        bool isDownloading = false;
        double progress = 0.0;

        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.system_update_rounded,
                    color: GlobalThemeData.darkColorScheme.primary),
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
                if (_currentVersion != null)
                  Text(context.l10n.current_version(_currentVersion!),
                      style: const TextStyle(fontSize: 16, color: Colors.grey)),
                const SizedBox(height: 12),
                if (info.forceUpdate)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                        border: Border.all(color: Colors.deepOrangeAccent),
                        borderRadius: BorderRadius.circular(4)),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_rounded,
                            size: 16, color: Colors.deepOrangeAccent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(context.l10n.update_required,
                              style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                if (info.forceUpdate) const SizedBox(height: 12),
                Text(
                  context.l10n.whats_new,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (info.changelog.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  ...info.changelog.map(
                    (change) => Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('• ', style: TextStyle(fontSize: 14)),
                        Expanded(
                          child: Text(change,
                              style: const TextStyle(fontSize: 14)),
                        ),
                      ],
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
                        GlobalThemeData.darkColorScheme.surfaceBright,
                    color: GlobalThemeData.darkColorScheme.primary,
                  ),
                  const SizedBox(height: 8),
                  Text(
                      context.l10n
                          .downloading((progress * 100).toStringAsFixed(0)),
                      style: const TextStyle(fontSize: 12)),
                ],
              ],
            ),
            actions: [
              if (!info.forceUpdate && !isDownloading)
                SoftButton(
                    onPressed: () => Navigator.pop(context),
                    label: context.l10n.later,
                    color: GlobalThemeData.darkColorScheme.onSurfaceVariant),
              isDownloading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : SoftButton(
                      onPressed: isDownloading
                          ? null
                          : () async {
                              setDialogState(() {
                                isDownloading = true;
                                progress = 0.0;
                              });

                              final success =
                                  await _updateService.downloadAndInstall(
                                info.downloadUrl,
                                (p) => setDialogState(() => progress = p),
                              );

                              if (success) {
                                if (context.mounted) {
                                  Navigator.pop(context);
                                  showSnackBar(
                                      context, context.l10n.installing_update,
                                      color: Colors.orangeAccent);
                                }
                              } else {
                                setDialogState(() => isDownloading = false);
                                if (context.mounted) {
                                  showSnackBar(
                                      context, context.l10n.update_failed,
                                      color: Colors.redAccent);
                                }
                              }
                            },
                      label: context.l10n.update_now,
                      color: GlobalThemeData.darkColorScheme.primary),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
