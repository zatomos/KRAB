import 'package:flutter/material.dart';
import 'package:krab/themes/global_theme_data.dart';

const double settingsGapS = 8;
const double settingsGapM = 16;
const double settingsGapL = 24;

/// One block of settings
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    this.info,
    this.action,
    required this.child,
  });

  final String title;

  /// Sits with the heading
  final Widget? info;

  /// Right-aligned
  final Widget? action;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: settingsGapS + 4, vertical: settingsGapS),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              letterSpacing: GlobalThemeData.mediumTracking),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (info != null) info!,
                    ],
                  ),
                ),
                if (action != null) action!,
              ],
            ),
            const SizedBox(height: settingsGapS),
            child,
          ],
        ),
      ),
    );
  }
}

/// Separates two sections.
class SectionDivider extends StatelessWidget {
  const SectionDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
        height: settingsGapL + settingsGapS,
        thickness: 1,
        color: Theme.of(context)
            .colorScheme
            .onSurfaceVariant
            .withValues(alpha: 0.2),
      );
}
