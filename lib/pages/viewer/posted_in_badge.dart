import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/group.dart';
import 'package:krab/pages/image_feed_page.dart';
import 'package:krab/pages/viewer/frosted.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';

/// How far the current-group highlight ring extends past an avatar's radius.
const double _highlightExtra = 1.5;

const double _radius = 13;

/// How far apart the overlapping avatars sit.
const double _step = 20;

/// Avatars beyond this collapse into a "+N" circle, so the pill can't overflow.
const int _maxVisible = 4;

/// The pill over the photo showing which groups it was posted in: an
/// overlapping cluster of group avatars, with the one being viewed ringed.
class PostedInBadge extends StatelessWidget {
  /// The groups, already ordered with the current one first.
  final List<Group> groups;

  /// The group being viewed, or null in the cross-group gallery.
  final String? currentGroupId;

  /// The viewer's entrance, 0..1.
  final double progress;

  const PostedInBadge({
    super.key,
    required this.groups,
    required this.currentGroupId,
    this.progress = 1,
  });

  @override
  Widget build(BuildContext context) {
    final count = groups.length;
    final hasOverflow = count > _maxVisible;
    final avatarCount = hasOverflow ? _maxVisible : count;
    final circleCount = hasOverflow ? _maxVisible + 1 : count;
    final clusterWidth = _step * (circleCount - 1) + _radius * 2;

    final highlightIndex = currentGroupId == null
        ? -1
        : groups.indexWhere((g) => g.id == currentGroupId);

    return FrostedSurface(
      borderRadius: BorderRadius.circular(999),
      tint: frostedTint,
      sigma: 10,
      progress: progress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Symbols.group_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            SizedBox(
              width: clusterWidth,
              height: _radius * 2,
              child: Stack(
                // The highlight ring extends past the cluster bounds.
                clipBehavior: Clip.none,
                children: [
                  // Non-highlighted avatars first...
                  for (int i = 0; i < avatarCount; i++)
                    if (i != highlightIndex)
                      Positioned(
                        left: i * _step,
                        child: _PillAvatar(group: groups[i]),
                      ),
                  if (hasOverflow)
                    Positioned(
                      left: avatarCount * _step,
                      child: CircleAvatar(
                        radius: _radius,
                        backgroundColor: Colors.white.withValues(alpha: 0.25),
                        child: Text(
                          "+${count - avatarCount}",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  if (highlightIndex >= 0 && highlightIndex < avatarCount)
                    Positioned(
                      left: highlightIndex * _step - _highlightExtra,
                      top: -_highlightExtra,
                      child: _PillAvatar(
                        group: groups[highlightIndex],
                        highlighted: true,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A group avatar in the pill cluster, ringed when it is the current group.
class _PillAvatar extends StatelessWidget {
  final Group group;
  final bool highlighted;

  const _PillAvatar({required this.group, this.highlighted = false});

  @override
  Widget build(BuildContext context) {
    final avatar = GroupAvatar(group, radius: _radius);
    if (!highlighted) return avatar;
    return Container(
      width: (_radius + _highlightExtra) * 2,
      height: (_radius + _highlightExtra) * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 1.5,
        ),
      ),
      child: avatar,
    );
  }
}

/// The frosted dialog behind the pill, listing the groups in full.
Future<void> showPostedInDialog(BuildContext context, List<Group> groups) {
  return showFrostedDialog<void>(
    context,
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
    content: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Symbols.group_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l10n.posted_in,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Symbols.close_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(context),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Flexible(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: groups.length,
            itemBuilder: (context, index) => _GroupTile(group: groups[index]),
          ),
        ),
      ],
    ),
  );
}

/// One group in the posted-in dialog. Tapping it opens that group's gallery.
class _GroupTile extends StatelessWidget {
  final Group group;

  const _GroupTile({required this.group});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: GroupAvatar(group, radius: 20),
      title: Text(
        group.name,
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      subtitle: FutureBuilder<SupabaseResponse<int>>(
        future: getGroupMemberCount(group.id),
        builder: (context, snapshot) {
          final count = snapshot.data?.data;
          return Text(
            count == null
                ? " "
                : "$count ${count == 1 ? context.l10n.member_singular : context.l10n.members_plural}",
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
          );
        },
      ),
      trailing: Icon(Symbols.chevron_right_rounded,
          color: Colors.white.withValues(alpha: 0.7)),
      onTap: () {
        Navigator.pop(context);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ImageFeedPage(group: group)),
        );
      },
    );
  }
}
