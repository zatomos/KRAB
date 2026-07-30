import 'package:flutter/material.dart';

import 'package:krab/widgets/auth/auth_scaffold.dart';

/// The failure line on the auth screens.
class AuthErrorBox extends StatelessWidget {
  const AuthErrorBox(this.message, {super.key, this.action});

  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final message = this.message;

    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: message == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: authGapM),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: authGapS + 2),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: Colors.redAccent, size: 18),
                        const SizedBox(width: authGapS),
                        Expanded(
                          child: Text(
                            message,
                            style: const TextStyle(
                                color: Colors.redAccent, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    if (action != null) action!,
                  ],
                ),
              ),
            ),
    );
  }
}
