import 'package:flutter/material.dart';

import 'package:krab/main.dart';

void showSnackBar(String message, {Color? color}) {
  final scaffoldMessenger = scaffoldMessengerKey.currentState;

  if (scaffoldMessenger != null) {
    final background =
        color ?? Theme.of(scaffoldMessenger.context).colorScheme.secondary;
    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(message),
        elevation: 4,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        backgroundColor: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  } else {
    debugPrint("showSnackBar called but no valid ScaffoldMessenger found.");
  }
}
