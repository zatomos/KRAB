import 'dart:async';

import 'package:flutter/material.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/themes/global_theme_data.dart';

enum SnackTone {
  neutral,
  success,
  failure,
  warning,
}

/// A label the user can tap.
class SnackAction {
  const SnackAction({
    required this.label,
    required this.onPressed,
    this.prominent = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool prominent;
}

void showSnackBar(
  String message, {
  SnackTone tone = SnackTone.neutral,
  List<SnackAction> actions = const [],
  Duration? duration,
}) {
  final scaffoldMessenger = scaffoldMessengerKey.currentState;

  if (scaffoldMessenger != null) {
    final background = switch (tone) {
      SnackTone.neutral =>
        Theme.of(scaffoldMessenger.context).colorScheme.secondary,
      SnackTone.success => GlobalThemeData.success,
      SnackTone.failure => Colors.red,
      SnackTone.warning => Colors.orangeAccent,
    };
    final visibleFor = duration ?? const Duration(seconds: 4);
    // Don't stack on top of a previous snackbar
    scaffoldMessenger.hideCurrentSnackBar();
    final controller = scaffoldMessenger.showSnackBar(
      SnackBar(
        content: _content(message, actions, background),
        elevation: 4,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        backgroundColor: background,
        duration: visibleFor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        padding: actions.length > 1
            ? const EdgeInsetsDirectional.only(start: 16, end: 8)
            : null,
        action: actions.length == 1
            ? SnackBarAction(
                label: actions.first.label,
                textColor: Colors.white,
                onPressed: actions.first.onPressed,
              )
            : null,
      ),
    );

    if (actions.isNotEmpty) {
      final timer = Timer(visibleFor, controller.close);
      controller.closed.whenComplete(timer.cancel);
    }
  } else {
    debugPrint("showSnackBar called but no valid ScaffoldMessenger found.");
  }
}

const double _contentPadding = 14;

Widget _content(String message, List<SnackAction> actions, Color background) {
  final text = Text(message, style: const TextStyle(color: Colors.white));
  if (actions.length < 2) return text;

  final buttons = [
    for (final action in actions) _actionButton(action, background)
  ];

  return Row(
    children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: _contentPadding),
          child: text,
        ),
      ),
      const SizedBox(width: 8),
      Builder(builder: (context) {
        final cap = MediaQuery.sizeOf(context).width / 2;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: cap),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: buttons,
          ),
        );
      }),
    ],
  );
}

Widget _actionButton(SnackAction action, Color background) {
  return TextButton(
    style: TextButton.styleFrom(
      foregroundColor: action.prominent ? background : Colors.white,
      backgroundColor: action.prominent ? Colors.white : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    onPressed: () {
      scaffoldMessengerKey.currentState
          ?.hideCurrentSnackBar(reason: SnackBarClosedReason.action);
      action.onPressed();
    },
    child: Text(
      action.label,
      style: const TextStyle(fontWeight: FontWeight.bold),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}
