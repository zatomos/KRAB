import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

enum FallbackType {
  firstLetter,
  icon,
}

class GroupOrUserAvatar extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final double radius;
  final bool useRandomColor;
  final FallbackType fallbackType;
  final IconData? fallbackIcon;

  const GroupOrUserAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.radius = 50,
    this.useRandomColor = false,
    this.fallbackType = FallbackType.firstLetter,
    this.fallbackIcon,
  });

  // Random color generator based on name
  Color _colorFromName(String text, BuildContext context) {
    if (text.isEmpty) {
      return Theme.of(context).colorScheme.primaryContainer;
    }
    final hash = text.codeUnits.fold<int>(0, (acc, c) => acc + c);
    final hue = (hash % 360).toDouble();
    final hsv = HSVColor.fromAHSV(1, hue, 0.5, 0.85);
    return hsv.toColor();
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;

    if (hasImage) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.transparent,
        backgroundImage: CachedNetworkImageProvider(imageUrl!),
        onBackgroundImageError: (_, __) {
          debugPrint('⚠️ Failed to load image for $name');
        },
      );
    }

    final bgColor = useRandomColor
        ? _colorFromName(name, context)
        : Theme.of(context).colorScheme.primaryContainer;

    Widget child;
    if (fallbackType == FallbackType.icon) {
      child = Icon(
        fallbackIcon ?? Icons.group_rounded,
        size: radius * 1.2,
        color: Theme.of(context).colorScheme.onPrimaryContainer,
      );
    } else {
      final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
      child = Text(
        initial,
        style: TextStyle(
          fontSize: radius,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: bgColor,
      child: child,
    );
  }
}
