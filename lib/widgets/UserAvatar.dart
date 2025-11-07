import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:krab/models/User.dart' as KRAB_User;

class UserAvatar extends StatelessWidget {
  final KRAB_User.User user;
  final double radius;

  const UserAvatar(
      this.user, {
        super.key,
        this.radius = 50,
      });

  @override
  Widget build(BuildContext context) {
    final hasPfp = user.pfpUrl.isNotEmpty;

    if (hasPfp) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.transparent,
        backgroundImage: CachedNetworkImageProvider(user.pfpUrl),
        onBackgroundImageError: (_, __) {
          debugPrint('⚠️ Failed to load pfp for ${user.username}');
        },
      );
    }

    // Fallback if no profile picture
    final String initial = user.username.isNotEmpty
        ? user.username[0].toUpperCase()
        : '?';

    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: radius,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
