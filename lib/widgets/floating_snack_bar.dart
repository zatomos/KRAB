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

FloatingSnackBarState? _current;

void showSnackBar(
  String message, {
  SnackTone tone = SnackTone.neutral,
  List<SnackAction> actions = const [],
  Duration? duration,
}) {
  final overlay = navigatorKey.currentState?.overlay;
  if (overlay == null) {
    debugPrint("showSnackBar called but no valid Overlay found.");
    return;
  }

  // Don't stack on top of a previous snackbar
  hideSnackBar();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => FloatingSnackBar(
      message: message,
      tone: tone,
      actions: actions,
      duration: duration ?? const Duration(seconds: 4),
      onDismissed: entry.remove,
    ),
  );
  overlay.insert(entry);
}

/// Close the snackbar on screen, if there is one.
void hideSnackBar() => _current?.close();

/// The floating message itself, living in the overlay.
class FloatingSnackBar extends StatefulWidget {
  const FloatingSnackBar({
    super.key,
    required this.message,
    required this.tone,
    required this.actions,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final SnackTone tone;
  final List<SnackAction> actions;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<FloatingSnackBar> createState() => FloatingSnackBarState();
}

class FloatingSnackBarState extends State<FloatingSnackBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    reverseDuration: const Duration(milliseconds: 200),
  );

  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _current = this;
    _controller.forward();
    _timer = Timer(widget.duration, close);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    if (_current == this) _current = null;
    super.dispose();
  }

  /// Slide back out, then take the entry out of the overlay.
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    if (_current == this) _current = null;
    await _controller.reverse();
    if (mounted) widget.onDismissed();
  }

  Color get _background => switch (widget.tone) {
        SnackTone.neutral => Theme.of(context).colorScheme.secondary,
        SnackTone.success => GlobalThemeData.success,
        SnackTone.failure => Colors.red,
        SnackTone.warning => Colors.orangeAccent,
      };

  @override
  Widget build(BuildContext context) {
    final background = _background;
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    return Positioned(
      left: 16,
      right: 16,
      bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
      child: SlideTransition(
        position:
            Tween(begin: const Offset(0, 1), end: Offset.zero).animate(curve),
        child: FadeTransition(
          opacity: curve,
          child: Dismissible(
            key: const ValueKey('floating-snack-bar'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _closing = true;
              _timer?.cancel();
              if (_current == this) _current = null;
              widget.onDismissed();
            },
            child: Material(
              color: background,
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: widget.actions.isEmpty
                    ? const EdgeInsets.symmetric(
                        horizontal: 16, vertical: _contentPadding)
                    : const EdgeInsetsDirectional.only(start: 16, end: 8),
                child: _content(widget.message, widget.actions, background),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const double _contentPadding = 14;

Widget _content(String message, List<SnackAction> actions, Color background) {
  final text = Text(message, style: const TextStyle(color: Colors.white));
  if (actions.isEmpty) return text;

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
      hideSnackBar();
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
