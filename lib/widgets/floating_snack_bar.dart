import 'dart:async';

import 'package:flutter/material.dart';

import 'package:krab/app_globals.dart';

void showSnackBar(
  String message, {
  Color? color,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  final scaffoldMessenger = scaffoldMessengerKey.currentState;

  if (scaffoldMessenger != null) {
    final background =
        color ?? Theme.of(scaffoldMessenger.context).colorScheme.secondary;
    final hasAction = actionLabel != null && onAction != null;
    final visibleFor = duration ?? const Duration(seconds: 4);
    // Don't stack on top of a previous snackbar
    scaffoldMessenger.hideCurrentSnackBar();
    final controller = scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(message),
        elevation: 4,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        backgroundColor: background,
        duration: visibleFor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        action: hasAction
            ? SnackBarAction(
                label: actionLabel,
                textColor: Colors.white,
                onPressed: onAction,
              )
            : null,
      ),
    );

    if (hasAction) {
      final timer = Timer(visibleFor, controller.close);
      controller.closed.whenComplete(timer.cancel);
    }
  } else {
    debugPrint("showSnackBar called but no valid ScaffoldMessenger found.");
  }
}
