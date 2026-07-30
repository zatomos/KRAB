import 'package:flutter/material.dart';

class AuthBackButton extends StatelessWidget {
  const AuthBackButton({super.key, this.onBack, this.enabled = true});

  /// Where back goes.
  ///
  /// Null falls back to popping, and to no button at all when this screen is the
  /// first route.
  final VoidCallback? onBack;

  /// False leaves the button off.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    if (onBack == null && !Navigator.of(context).canPop()) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.topLeft,
      child: BackButton(
        color: Theme.of(context).colorScheme.onSurface,
        onPressed: onBack,
      ),
    );
  }
}
