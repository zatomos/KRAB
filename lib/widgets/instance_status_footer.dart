import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/instance/instances.dart';

/// A line pinned under a list saying which servers it is not speaking for.
class InstanceStatusFooter extends StatelessWidget {
  const InstanceStatusFooter({
    super.key,
    required this.pending,
    required this.unavailable,
    required this.failure,
  });

  /// Servers that have not answered yet.
  final List<KrabInstance> pending;

  /// Servers that answered with nothing usable.
  final List<KrabInstance> unavailable;

  /// The failure line, built from the joined server labels, so each screen can
  /// name what it could not load.
  final String Function(String servers) failure;

  static String _labels(List<KrabInstance> instances) =>
      instances.map((i) => i.label).join(', ');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final Widget leading;
    final String message;
    final Color color;

    if (pending.isNotEmpty) {
      color = colors.onSurfaceVariant;
      leading = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
      message = context.l10n.servers_still_loading(_labels(pending));
    } else if (unavailable.isNotEmpty) {
      color = colors.error;
      leading = Icon(Symbols.cloud_off_rounded, size: 18, color: color);
      message = failure(_labels(unavailable));
    } else {
      return const SizedBox.shrink();
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: color, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
