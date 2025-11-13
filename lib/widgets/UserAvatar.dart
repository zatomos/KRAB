import 'package:flutter/material.dart';
import 'package:krab/models/User.dart' as KRAB_User;
import 'GroupOrUserAvatar.dart';

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
    return GroupOrUserAvatar(
      name: user.username,
      imageUrl: user.pfpUrl,
      radius: radius,
      fallbackType: FallbackType.firstLetter,
    );
  }
}
