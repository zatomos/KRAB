import 'package:flutter/material.dart';

class AuthBackButton extends StatelessWidget {
  const AuthBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Navigator.of(context).canPop()) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.topLeft,
      child: BackButton(color: Theme.of(context).colorScheme.onSurface),
    );
  }
}
