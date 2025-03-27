import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
  final String username;
  final double radius;

  const UserAvatar(
    this.username, {
    super.key,
    this.radius = 50,
  });

  @override
  Widget build(BuildContext context) {
    if (username.isEmpty) {
      return CircleAvatar(
        radius: radius,
        child: Icon(
          Icons.person,
          size: radius,
        ),
      );
    }
    return CircleAvatar(
      radius: radius,
      child: Text(
        username[0].toUpperCase(),
        style: TextStyle(
          fontSize: radius,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
