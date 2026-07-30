import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';

/// A group's member count, as an icon and a count.
class MemberCountLabel extends StatelessWidget {
  const MemberCountLabel(this.count,
      {super.key, this.fontSize = 14, this.color});

  final int count;
  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    final noun =
        count == 1 ? context.l10n.member_singular : context.l10n.members_plural;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Symbols.group_rounded, size: fontSize + 1, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '$count $noun',
            style: TextStyle(fontSize: fontSize, color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
