import 'dart:async';

import 'package:flutter/widgets.dart';

/// Gates a loading placeholder against a delay and a minimum display time,
/// so that it doesn't flash for very short loads.
class DelayedLoading extends StatefulWidget {
  final bool loading;
  final Widget placeholder;
  final Widget child;
  final Duration delay;
  final Duration minDuration;

  const DelayedLoading({
    super.key,
    required this.loading,
    required this.placeholder,
    required this.child,
    this.delay = const Duration(milliseconds: 200),
    this.minDuration = const Duration(milliseconds: 300),
  });

  @override
  State<DelayedLoading> createState() => _DelayedLoadingState();
}

enum _Phase { idle, waiting, showing }

class _DelayedLoadingState extends State<DelayedLoading> {
  _Phase _phase = _Phase.idle;
  Timer? _timer;
  DateTime? _shownAt;

  @override
  void initState() {
    super.initState();
    if (widget.loading) _enterWaiting();
  }

  @override
  void didUpdateWidget(DelayedLoading old) {
    super.didUpdateWidget(old);
    if (widget.loading == old.loading) return;
    if (widget.loading) {
      _timer?.cancel();
      if (_phase == _Phase.idle) _enterWaiting();
    } else if (_phase == _Phase.showing) {
      _startMinHold();
    } else {
      _timer?.cancel();
      _phase = _Phase.idle;
    }
  }

  void _enterWaiting() {
    _phase = _Phase.waiting;
    _timer = Timer(widget.delay, () {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.showing;
        _shownAt = DateTime.now();
      });
    });
  }

  void _startMinHold() {
    final shownFor = DateTime.now().difference(_shownAt ?? DateTime.now());
    final remaining = widget.minDuration - shownFor;
    _timer?.cancel();
    if (remaining <= Duration.zero) {
      _phase = _Phase.idle;
    } else {
      _timer = Timer(remaining, () {
        if (mounted) setState(() => _phase = _Phase.idle);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.showing:
        return widget.placeholder;
      case _Phase.waiting:
        return const SizedBox.shrink();
      case _Phase.idle:
        return widget.child;
    }
  }
}
