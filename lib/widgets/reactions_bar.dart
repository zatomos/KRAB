import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/reaction.dart';
import 'package:krab/widgets/emoji_picker_sheet.dart';
import 'package:krab/widgets/reactors_sheet.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/services/cache/reaction_cache.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/shared_image_api.dart';

/// Horizontal strip of emoji reaction chips with an add reaction button,
/// laid over the dark image viewer.
class ReactionsBar extends StatefulWidget {
  /// The image, with every copy of it. Tallies are added up across the copies
  /// and a new reaction is written to one of them.
  final SharedImage image;

  /// The server whose group the image was opened from, or null in the
  /// cross-group feed.
  final String? preferInstanceId;

  const ReactionsBar({super.key, required this.image, this.preferInstanceId});

  @override
  State<ReactionsBar> createState() => ReactionsBarState();
}

class ReactionsBarState extends State<ReactionsBar> {
  List<ReactionSummary> _reactions = const [];

  /// Which emoji the viewer holds on each copy, so a write can leave alone the
  /// copies already in the state being asked for.
  Map<String, Set<String>> _mineByInstance = const {};

  SharedImageApi get _api => SharedImageApi(widget.image);

  /// Whether this bar speaks for one server rather than the whole image.
  bool get _scoped => widget.preferInstanceId != null;

  /// The shared cache holds the whole image's tally, keyed by its primary copy.
  /// A scoped bar is showing something else, so it keeps its tally to itself
  /// rather than writing one view's answer where the other reads it.
  ReactionCache? get _cache => _scoped
      ? null
      : InstanceRegistry.instance
          .byId(widget.image.primary.instanceId)
          ?.reactions;

  String get _cacheKey => widget.image.primary.id;

  @override
  void initState() {
    super.initState();
    _reactions = _cache?.cached(_cacheKey) ?? const [];
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ReactionsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.identity != widget.image.identity) {
      _reactions = _cache?.cached(_cacheKey) ?? const [];
      _refresh();
    }
  }

  /// Re-fetch the reaction tally from the server. Public so the viewer can
  /// refresh the bar after returning from the comments sheet.
  Future<void> reload() => _refresh();

  /// Pull the latest tally without clearing what's shown, so the bar updates in
  /// place rather than blanking out.
  Future<void> _refresh() async {
    final identity = widget.image.identity;
    final result = await _api.reactions(onlyOn: widget.preferInstanceId);
    if (!mounted || identity != widget.image.identity || result == null) return;
    _cache?.put(_cacheKey, result.tally);
    setState(() {
      _reactions = result.tally;
      _mineByInstance = result.mineByInstance;
    });
  }

  /// Apply emoji, then reconcile with the server.
  Future<void> _toggle(String emoji) async {
    final identity = widget.image.identity;
    final previous = _reactions;
    final updated = applyToggle(previous, emoji);
    setState(() => _reactions = updated);
    _cache?.put(_cacheKey, updated);

    // A gallery acts on its own server, either way: what is on screen is that
    // server's tally, and it is what changes. The feed acts on every copy.
    final wasReacted = previous.any((r) => r.emoji == emoji && r.reactedByMe);
    final response = await _api.setReaction(
      emoji,
      on: !wasReacted,
      mineByInstance: _mineByInstance,
      onlyOn: widget.preferInstanceId,
    );
    if (response.success) {
      // So a second tap knows which copies it still has to change.
      if (response.data != null) _mineByInstance = response.data!;
      return;
    }

    _cache?.put(_cacheKey, previous);
    if (!mounted || identity != widget.image.identity) return;
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

  void _openReactors() => showReactorsSheet(context, widget.image,
      preferInstanceId: widget.preferInstanceId);

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
            if (hidden > 0) _OverflowChip(count: hidden, onTap: _openReactors),
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
