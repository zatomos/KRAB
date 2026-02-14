import 'package:flutter/material.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'group_or_user_avatar.dart';

class UserAvatar extends StatelessWidget {
  final krab_user.User user;
  final double radius;

  const UserAvatar(
      this.user, {
        super.key,
        this.radius = 50,
      });

  @override
  Widget build(BuildContext context) {
    return GroupOrUserAvatar(
      name: user.username,
      imageUrl: user.pfpUrl,
      radius: radius,
      fallbackType: FallbackType.firstLetter,
    );
  }
}
