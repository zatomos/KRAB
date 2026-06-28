import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';

/// One person's reaction with a given emoji.
class _Reactor {
  final String emoji;
  final String userId;
  final String username;

  const _Reactor({
    required this.emoji,
    required this.userId,
    required this.username,
  });

  static _Reactor fromJson(Map<String, dynamic> json) => _Reactor(
        emoji: json['emoji']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
      );
}

/// A user and every emoji they reacted with, as shown in one row.
class _ReactorRow {
  final String userId;
  final String username;
  final List<String> emojis;

  const _ReactorRow({
    required this.userId,
    required this.username,
    required this.emojis,
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
  List<_Reactor> _reactors = const [];

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
        .map((e) => _Reactor.fromJson(e as Map<String, dynamic>))
        .toList();

    // Order emoji tabs by descending usage
    final counts = <String, int>{};
    for (final r in reactors) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    }
    final emojis = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });

    setState(() {
      _reactors = reactors;
      _emojis = emojis;
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

  /// Collapse every reactor into one row per user carrying all the emojis
  /// that user reacted with
  List<_ReactorRow> _rowsFor(String? emoji) {
    final source =
        emoji == null ? _reactors : _reactors.where((r) => r.emoji == emoji);

    final byUser = <String, _ReactorRow>{};
    final order = <String>[];
    for (final r in source) {
      final existing = byUser[r.userId];
      if (existing == null) {
        byUser[r.userId] =
            _ReactorRow(userId: r.userId, username: r.username, emojis: [r.emoji]);
        order.add(r.userId);
      } else {
        existing.emojis.add(r.emoji);
      }
    }
    return [for (final id in order) byUser[id]!];
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

    const double rowHeight = 52;
    const double minListHeight = 200;
    final allRows = _rowsFor(null);
    final listHeight =
        math.max(math.min(allRows.length, 6) * rowHeight, minListHeight)
            .toDouble();

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
                  _reactorList(allRows),
                  for (final emoji in _emojis) _reactorList(_rowsFor(emoji)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reactorList(List<_ReactorRow> rows) {
    return ListView.builder(
      physics: rows.length <= 6
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
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              UserAvatar(user, radius: 20),
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
