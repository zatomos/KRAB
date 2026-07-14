import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/cache/profile_picture_cache.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';

/// One person's reaction with a given emoji.
class Reactor {
  final String emoji;
  final String userId;
  final String username;

  const Reactor({
    required this.emoji,
    required this.userId,
    required this.username,
  });

  static Reactor fromJson(Map<String, dynamic> json) => Reactor(
        emoji: json['emoji']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
      );
}

/// A user and every emoji they reacted with, as shown in one row.
class ReactorRow {
  final String userId;
  final String username;
  final List<String> emojis;

  const ReactorRow({
    required this.userId,
    required this.username,
    required this.emojis,
  });
}

/// Collapse the reactions into one row per person, carrying every emoji they
/// used.
/// With emoji given, only that emoji's reactions are counted.
List<ReactorRow> groupReactors(List<Reactor> reactors, {String? emoji}) {
  final source =
      emoji == null ? reactors : reactors.where((r) => r.emoji == emoji);

  final byUser = <String, ReactorRow>{};
  final order = <String>[];
  for (final r in source) {
    final existing = byUser[r.userId];
    if (existing == null) {
      byUser[r.userId] =
          ReactorRow(userId: r.userId, username: r.username, emojis: [r.emoji]);
      order.add(r.userId);
    } else {
      existing.emojis.add(r.emoji);
    }
  }
  return [for (final id in order) byUser[id]!];
}

/// The distinct emojis used, most-used first, then alphabetically.
List<String> emojisByUse(List<Reactor> reactors) {
  final counts = <String, int>{};
  for (final r in reactors) {
    counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
  }
  return counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
}

/// Open the reactors sheet for an image
Future<void> showReactorsSheet(BuildContext context, String imageId) {
  final screenHeight = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    constraints: BoxConstraints(maxHeight: screenHeight * 0.7),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ReactorsSheet(imageId: imageId),
  );
}

class _ReactorsSheet extends StatefulWidget {
  final String imageId;

  const _ReactorsSheet({required this.imageId});

  @override
  State<_ReactorsSheet> createState() => _ReactorsSheetState();
}

class _ReactorsSheetState extends State<_ReactorsSheet> {
  static const double _avatarRadius = 20;
  static const double _rowVerticalPadding = 12;
  static double get _rowHeight => _avatarRadius * 2 + _rowVerticalPadding * 2;

  List<Reactor> _reactors = const [];

  /// Distinct emojis ordered by how many used them
  List<String> _emojis = const [];

  /// Resolved profile-picture URL per user id
  final Map<String, String> _pfpUrls = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final response = await getImageReactors(widget.imageId);
    if (!mounted) return;
    if (!response.success || response.data == null) {
      setState(() => _loading = false);
      return;
    }

    final reactors = response.data!
        .map((e) => Reactor.fromJson(e as Map<String, dynamic>))
        .toList();

    setState(() {
      _reactors = reactors;
      _emojis = emojisByUse(reactors);
      _loading = false;
    });

    // Resolve avatars for each distinct user
    final cache = ProfilePictureCache.of(supabase);
    for (final userId in reactors.map((r) => r.userId).toSet()) {
      cache.getUrl(userId, ttl: const Duration(hours: 1)).then((url) {
        if (!mounted || url == null || url.isEmpty) return;
        setState(() => _pfpUrls[userId] = url);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_reactors.isEmpty) {
      return SizedBox(
        height: 120,
        child: Center(child: Text(context.l10n.no_reactions)),
      );
    }

    const double minListHeight = 200;
    final allRows = groupReactors(_reactors);
    final maxListHeight =
        math.max(MediaQuery.sizeOf(context).height * 0.7 - 140, minListHeight);
    final listHeight = (allRows.length * _rowHeight)
        .toDouble()
        .clamp(minListHeight, maxListHeight);

    // "All" tab first, then one tab per emoji
    return DefaultTabController(
      length: _emojis.length + 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.reactions_title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: '${context.l10n.reactions_all} · ${allRows.length}'),
                for (final emoji in _emojis)
                  Tab(
                    text:
                        '$emoji ${_reactors.where((r) => r.emoji == emoji).length}',
                  ),
              ],
            ),
            SizedBox(
              height: listHeight,
              child: TabBarView(
                children: [
                  _reactorList(allRows, listHeight),
                  for (final emoji in _emojis)
                    _reactorList(
                        groupReactors(_reactors, emoji: emoji), listHeight),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reactorList(List<ReactorRow> rows, double listHeight) {
    final fits = rows.length * _rowHeight <= listHeight;
    return ListView.builder(
      physics: fits
          ? const NeverScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        final user = krab_user.User(
          id: row.userId,
          username: row.username,
          pfpUrl: _pfpUrls[row.userId] ?? '',
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: _rowVerticalPadding),
          child: Row(
            children: [
              UserAvatar(user, radius: _avatarRadius),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  row.username.isEmpty ? '…' : row.username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              _EmojiCluster(
                emojis: row.emojis,
                maxWidth: MediaQuery.sizeOf(context).width * 0.4,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A horizontally scrollable row of emojis
class _EmojiCluster extends StatefulWidget {
  final List<String> emojis;
  final double maxWidth;

  const _EmojiCluster({required this.emojis, required this.maxWidth});

  @override
  State<_EmojiCluster> createState() => _EmojiClusterState();
}

class _EmojiClusterState extends State<_EmojiCluster> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _onScroll() => setState(() {});

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool fadeLeft = false;
    bool fadeRight = false;
    if (_controller.hasClients && _controller.position.hasContentDimensions) {
      final p = _controller.position;
      if (p.maxScrollExtent > 0.5) {
        fadeLeft = p.pixels < p.maxScrollExtent - 0.5;
        fadeRight = p.pixels > p.minScrollExtent + 0.5;
      }
    }

    final scrollView = SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Text(
        widget.emojis.join(' '),
        style: const TextStyle(fontSize: 18),
      ),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: (fadeLeft || fadeRight)
          ? ShaderMask(
              shaderCallback: (rect) => LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  fadeLeft ? Colors.transparent : Colors.black,
                  Colors.black,
                  Colors.black,
                  fadeRight ? Colors.transparent : Colors.black,
                ],
                stops: const [0.0, 0.12, 0.88, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: scrollView,
            )
          : scrollView,
    );
  }
}
