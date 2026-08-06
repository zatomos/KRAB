import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'avatar_color.dart';
import 'package:krab/themes/global_theme_data.dart';

enum FallbackType {
  firstLetter,
  icon,
}

const Duration _fade = Duration(milliseconds: 100);

class GroupOrUserAvatar extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final double radius;
  final bool useRandomColor;
  final FallbackType fallbackType;
  final IconData? fallbackIcon;
  final String? cacheKey;

  const GroupOrUserAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.radius = 50,
    this.useRandomColor = false,
    this.fallbackType = FallbackType.firstLetter,
    this.fallbackIcon,
    this.cacheKey,
  });

  Widget _fallback(BuildContext context) {
    final bgColor = useRandomColor
        ? colorFromName(name, context)
        : Theme.of(context).colorScheme.primaryContainer;

    return CircleAvatar(
      radius: radius,
      backgroundColor: bgColor,
      child: fallbackType == FallbackType.icon
          ? Icon(
              fallbackIcon ?? Icons.group_rounded,
              size: radius * 1.2,
              color: GlobalThemeData.onAccent,
            )
          : Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                fontSize: radius,
                fontWeight: FontWeight.w500,
                letterSpacing: GlobalThemeData.mediumTracking,
                color: GlobalThemeData.onAccent,
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) return _fallback(context);

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        cacheKey: cacheKey,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        fadeInDuration: _fade,
        fadeOutDuration: _fade,
        placeholderFadeInDuration: _fade,
        placeholder: (context, __) => _fallback(context),
        errorWidget: (context, __, ___) {
          debugPrint('⚠️ Failed to load image for $name');
          return _fallback(context);
        },
      ),
    );
  }
}
