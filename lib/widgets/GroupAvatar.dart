import 'package:flutter/material.dart';
import 'package:krab/models/Group.dart';
import 'GroupOrUserAvatar.dart';

class GroupAvatar extends StatelessWidget {
  final Group group;
  final double radius;

  const GroupAvatar(
      this.group, {
        super.key,
        this.radius = 50,
      });

  @override
  Widget build(BuildContext context) {
    return GroupOrUserAvatar(
      name: group.name,
      imageUrl: group.iconUrl,
      radius: radius,
      useRandomColor: true,
      fallbackType: FallbackType.icon,
      fallbackIcon: Icons.group_rounded,
    );
  }
}
