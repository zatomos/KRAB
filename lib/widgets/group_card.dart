import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/pages/group_images_page.dart';
import 'package:krab/models/group.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/group_avatar.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/services/time_formatting.dart';

class GroupCard extends StatefulWidget {
  final Group group;
  final VoidCallback? onReturn;

  const GroupCard({super.key, required this.group, this.onReturn});

  @override
  State<GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<GroupCard> {
  late Group _group;
  bool isFavorite = false;

  @override
  void initState() {
    super.initState();
    _group = widget.group; // make a mutable copy
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadFavoriteStatus();
  }

  Future<void> _loadFavoriteStatus() async {
    bool favorite = await UserPreferences.isGroupFavorite(_group.id);
    if (mounted) {
      setState(() => isFavorite = favorite);
    }
  }

  Future<int> _fetchGroupMemberCount(String groupId) async {
    final response = await getGroupMemberCount(groupId);
    if (response.error != null) {
      if (!mounted) return 0;
      showSnackBar("${response.error}");
      return 0;
    }
    return response.data!;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push<Group>(
          context,
          MaterialPageRoute(
            builder: (_) => GroupImagesPage(group: _group),
          ),
        );
        // Call the callback when returning
        widget.onReturn?.call();
      },
      child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
          elevation: 0,
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(15, 2, 5, 2),
            minVerticalPadding: 0,
            visualDensity: VisualDensity.compact,

            leading: GroupAvatar(_group, radius: 25),

            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Group name
                Expanded(
                  child: Text(
                    _group.name,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                const SizedBox(width: 8),

                // Last image time
                if (widget.group.latestImageAt != null)
                  Text(
                    timeAgoShort(context, widget.group.latestImageAt!),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),

            subtitle: FutureBuilder<int>(
              future: _fetchGroupMemberCount(_group.id),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Text(" ");
                } else if (snapshot.hasError) {
                  return Text(context.l10n.error_loading_members);
                } else {
                  final count = snapshot.data ?? 0;
                  return Text(
                    "$count ${count == 1 ? context.l10n.member_singular : context.l10n.members_plural}",
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  );
                }
              },
            ),

            // STAR FAVORITE BUTTON (moved closer to right edge)
            trailing: Padding(
              padding: EdgeInsets.zero,
              child: IconButton(
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
                icon: Icon(
                  Symbols.star_rounded,
                  color: isFavorite ? Colors.amber : Colors.grey,
                  fill: isFavorite ? 1 : 0,
                  size: 28,
                ),
                onLongPress: () {
                  showSnackBar(context.l10n.starred_groups_long_press);
                },
                onPressed: () async {
                  final l10n = context.l10n;
                  if (isFavorite) {
                    await UserPreferences.removeFavoriteGroup(_group.id);
                    showSnackBar(l10n.removed_group_favorites(_group.name));
                  } else {
                    await UserPreferences.addFavoriteGroup(_group.id);
                    showSnackBar(l10n.added_group_favorites(_group.name));
                  }
                  if (!mounted) return;
                  setState(() => isFavorite = !isFavorite);
                },
              ),
            ),
          )),
    );
  }
}
