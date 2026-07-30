import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/instance/krab_instance.dart';

class ServerLabel extends StatelessWidget {
  const ServerLabel(this.instance, {super.key, this.fontSize = 12, this.color});

  final KrabInstance? instance;
  final double fontSize;
  final Color? color;

  /// Whether naming a server tells the reader anything here.
  static bool get relevant => InstanceRegistry.instance.all.length > 1;

  @override
  Widget build(BuildContext context) {
    final label = instance?.label;
    if (label == null || label.isEmpty) return const SizedBox.shrink();

    final color = this.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Symbols.dns_rounded, size: fontSize + 1, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: TextStyle(fontSize: fontSize, color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
