import 'package:flutter/material.dart';

import 'package:krab/main.dart';

void showSnackBar(BuildContext? context, String message, {Color? color}) {
  ScaffoldMessengerState? scaffoldMessenger;

  if (context != null) {
    scaffoldMessenger = ScaffoldMessenger.maybeOf(context);
  }

  // Fallback to the global ScaffoldMessenger if needed
  scaffoldMessenger ??= scaffoldMessengerKey.currentState;

  if (scaffoldMessenger != null) {
    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(message),
        elevation: 4,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        backgroundColor: color ??
            (context != null ? Theme.of(context).colorScheme.secondary : Colors.grey[800]),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  } else {
    debugPrint("showSnackBar called but no valid ScaffoldMessenger found.");
  }
}
