import 'package:flutter/material.dart';

import 'package:krab/themes/global_theme_data.dart';

/// The panel the connect and login screens sit on.
class AuthCard extends StatelessWidget {
  final Widget child;
  static const maxWidth = 420.0;

  /// Rings the card in green.
  final bool success;

  const AuthCard({super.key, required this.child, this.success = false});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: success ? GlobalThemeData.success : Colors.transparent,
          width: 2,
        ),
        boxShadow: success
            ? [
                BoxShadow(
                  color: GlobalThemeData.success.withValues(alpha: 0.3),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
