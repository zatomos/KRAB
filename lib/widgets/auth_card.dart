import 'package:flutter/material.dart';


/// The panel the connect and login screens sit on.
class AuthCard extends StatelessWidget {
  final Widget child;
  static const maxWidth = 420.0;

  const AuthCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceBright,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}
