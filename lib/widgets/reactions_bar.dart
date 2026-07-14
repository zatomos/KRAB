import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/reaction.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/cache/reaction_cache.dart';
import 'package:krab/widgets/emoji_picker_sheet.dart';
import 'package:krab/widgets/reactors_sheet.dart';
import 'package:krab/widgets/floating_snack_bar.dart';

/// Horizontal strip of emoji reaction chips with an add reaction button,
/// laid over the dark photo viewer.
class ReactionsBar extends StatefulWidget {
  final String imageId;

  const ReactionsBar({super.key, required this.imageId});

  @override
  State<ReactionsBar> createState() => ReactionsBarState();
}

class ReactionsBarState extends State<ReactionsBar> {
  List<ReactionSummary> _reactions = const [];

  @override
  void initState() {
    super.initState();
    _reactions = cachedReactions(widget.imageId);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ReactionsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageId != widget.imageId) {
      _reactions = cachedReactions(widget.imageId);
      _refresh();
    }
  }

  /// Re-fetch the reaction tally from the server. Public so the viewer can
  /// refresh the bar after returning from the comments sheet.
  Future<void> reload() => _refresh();

  /// Pull the latest tally without clearing what's shown, so the bar updates in
  /// place rather than blanking out.
  Future<void> _refresh() async {
    final imageId = widget.imageId;
    final list = await fetchImageReactions(imageId);
    if (!mounted || imageId != widget.imageId || list == null) return;
    setState(() => _reactions = list);
  }

  /// Apply emoji, then reconcile with the server.
  Future<void> _toggle(String emoji) async {
    final imageId = widget.imageId;
    final previous = _reactions;
    final updated = applyToggle(previous, emoji);
    setState(() => _reactions = updated);
    cacheReactions(imageId, updated);

    final response = await toggleReaction(imageId, emoji);
    if (response.success) return;

    cacheReactions(imageId, previous);
    if (!mounted || imageId != widget.imageId) return;
    setState(() => _reactions = previous);
    showSnackBar(
      context.l10n.error_reacting(context.errorText(response.error)),
      tone: SnackTone.failure,
    );
  }

  /// Adds the emoji if the user hadn't reacted with it, removes their reaction
  /// otherwise, dropping chips that fall to zero.
  @visibleForTesting
  static List<ReactionSummary> applyToggle(
      List<ReactionSummary> current, String emoji) {
    final result = <ReactionSummary>[];
    var found = false;
    for (final r in current) {
      if (r.emoji != emoji) {
        result.add(r);
        continue;
      }
      found = true;
      final delta = r.reactedByMe ? -1 : 1;
      final count = r.count + delta;
      if (count > 0) {
        result.add(r.copyWith(count: count, reactedByMe: !r.reactedByMe));
      }
    }
    if (!found) {
      result.add(ReactionSummary(emoji: emoji, count: 1, reactedByMe: true));
    }
    return result;
  }

  Future<void> _openPicker() async {
    final emoji = await showEmojiPicker(context);
    if (emoji != null) await _toggle(emoji);
  }

  void _openReactors() => showReactorsSheet(context, widget.imageId);

  /// How many reaction chips fit across the phone width.
  static int visibleChipsFor(double width, int reactionCount) {
    if (reactionCount == 0) return 0;

    int fitting(double reserved) =>
        ((width - reserved) / (_kChipWidth + _kChipSpacing)).floor();

    // Room for the add button.
    final withoutOverflow = fitting(_kAddChipWidth + _kChipSpacing);
    if (reactionCount <= withoutOverflow) return reactionCount;

    // They don't all fit, so the "+N" chip has to be paid for too.
    final withOverflow = fitting(
      _kAddChipWidth + _kChipSpacing + _kOverflowChipWidth + _kChipSpacing,
    );
    // Always leave at least one reaction visible.
    return withOverflow.clamp(1, reactionCount);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxVisible =
            visibleChipsFor(constraints.maxWidth, _reactions.length);
        final hidden = _reactions.length - maxVisible;
        final visible = _reactions.take(maxVisible);

        // Right-aligned, grow upward.
        return Wrap(
          alignment: WrapAlignment.end,
          spacing: _kChipSpacing,
          runSpacing: _kChipSpacing,
          children: [
            for (final r in visible)
              _ReactionChip(
                reaction: r,
                onTap: () => _toggle(r.emoji),
                onLongPress: _openReactors,
              ),
            // Tapping the overflow chip opens the full reactors list.
            if (hidden > 0)
              _OverflowChip(count: hidden, onTap: _openReactors),
            _AddReactionChip(onTap: _openPicker),
          ],
        );
      },
    );
  }
}

const double _kChipSpacing = 8;

/// Roughly one emoji plus a two-digit count.
const double _kChipWidth = 64;
const double _kAddChipWidth = 44;
const double _kOverflowChipWidth = 52;

/// Shared height
const double _kChipHeight = 42;

class _Chip extends StatelessWidget {
  final Color color;
  final Color borderColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  const _Chip({
    required this.color,
    required this.borderColor,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(_kChipHeight / 2),
      child: BackdropFilter.grouped(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Material(
          color: color,
          shape: StadiumBorder(side: BorderSide(color: borderColor, width: 1)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            onLongPress: onLongPress,
            child: SizedBox(
              height: _kChipHeight,
              child: Center(
                widthFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final ReactionSummary reaction;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ReactionChip({
    required this.reaction,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final mine = reaction.reactedByMe;
    final accent = Theme.of(context).colorScheme.primary;
    return _Chip(
      color: mine
          ? accent.withValues(alpha: 0.35)
          : Colors.black.withValues(alpha: 0.4),
      borderColor: mine ? accent : Colors.white.withValues(alpha: 0.2),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(reaction.emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 6),
          Text(
            '${reaction.count}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddReactionChip extends StatelessWidget {
  final VoidCallback onTap;

  const _AddReactionChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _Chip(
      color: Colors.black.withValues(alpha: 0.4),
      borderColor: Colors.white.withValues(alpha: 0.2),
      onTap: onTap,
      child: const Icon(Symbols.add_reaction_rounded,
          color: Colors.white, size: 18),
    );
  }
}

/// The "+N" overflow chip
class _OverflowChip extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _OverflowChip({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _Chip(
      color: Colors.black.withValues(alpha: 0.4),
      borderColor: Colors.white.withValues(alpha: 0.2),
      onTap: onTap,
      child: Text(
        '+$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
