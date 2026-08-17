import 'package:flutter/material.dart';
class CrossFade extends StatelessWidget {
  final Object? token;
  final Widget child;
  final Alignment alignment;

  static const Duration _duration = Duration(milliseconds: 80);

  const CrossFade({
    super.key,
    required this.token,
    required this.child,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: _duration,
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeOut,
        layoutBuilder: (current, previous) => Stack(
          alignment: alignment,
          children: [...previous, if (current != null) current],
        ),
        child: KeyedSubtree(key: ValueKey(token), child: child),
      );
}
