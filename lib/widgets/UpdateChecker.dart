import 'package:flutter/material.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/services/update_service.dart';
import 'package:krab/widgets/UpdateDialog.dart';

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
        context.l10n.update_check_failed,
        color: Colors.orangeAccent,
      );
      return;
    }

    if (result.hasUpdate && result.info != null && mounted) {
      showUpdateDialog(
        context: context,
        updateService: _updateService,
        info: result.info!,
        currentVersion: _currentVersion,
      );
    } else {
      debugPrint('No update available');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
