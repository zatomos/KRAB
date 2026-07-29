import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/pages/image_feed_page.dart';
import 'package:krab/models/group.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/widgets/server_label.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/services/time_formatting.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/instance/instance_registry.dart';

class GroupCard extends StatefulWidget {
  final Group group;
  final VoidCallback? onReturn;

  /// Member count resolved by the caller. When provided the card shows it
  /// directly instead of fetching its own.
  final int? memberCount;

  /// Whether to name the server this group is on if we are connected to more
  /// than one server.
  final bool showOrigin;

  const GroupCard({
    super.key,
    required this.group,
    this.onReturn,
    this.memberCount,
    this.showOrigin = false,
  });

  @override
  State<GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<GroupCard> {
  late Group _group;

  /// The server this group lives on. Null once that server is disconnected.
  KrabInstance? get _instance =>
      InstanceRegistry.instance.byId(_group.instanceId);
  Future<int>? _memberCountFuture;
  bool isFavorite = false;

  @override
  void initState() {
    super.initState();
    _group = widget.group; // make a mutable copy
    if (widget.memberCount == null) {
      _memberCountFuture = _fetchGroupMemberCount(_group.id);
    }
  }

  @override
  void didUpdateWidget(GroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.id != widget.group.id) {
      _group = widget.group;
      _memberCountFuture =
          widget.memberCount == null ? _fetchGroupMemberCount(_group.id) : null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadFavoriteStatus();
  }

  Future<void> _loadFavoriteStatus() async {
    bool favorite =
        await UserPreferences.isGroupFavorite(_group.instanceId, _group.id);
    if (mounted) {
      setState(() => isFavorite = favorite);
    }
  }

  Future<int> _fetchGroupMemberCount(String groupId) async {
    final instance = _instance;
    if (instance == null) return 0;
    final response = await instance.api.getGroupMemberCount(groupId);
    if (response.error != null) {
      debugPrint("Failed to load member count: ${response.error}");
      if (!mounted) return 0;
      showSnackBar(context.l10n.error_loading_member_count,
          tone: SnackTone.failure);
      return 0;
    }
    return response.data!;
  }

  Widget _memberCountLabel(BuildContext context, int count) {
    final noun =
        count == 1 ? context.l10n.member_singular : context.l10n.members_plural;
    return Text(
      "$count $noun",
      style: const TextStyle(fontSize: 14, color: Colors.grey),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push<Group>(
          context,
          MaterialPageRoute(
            builder: (_) => ImageFeedPage(group: _group),
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

            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.memberCount != null
                    ? _memberCountLabel(context, widget.memberCount!)
                    : FutureBuilder<int>(
                        future: _memberCountFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Text(" ");
                          } else if (snapshot.hasError) {
                            return Text(context.l10n.error_loading_members);
                          } else {
                            return _memberCountLabel(
                                context, snapshot.data ?? 0);
                          }
                        },
                      ),
                if (widget.showOrigin) ServerLabel(_instance),
              ],
            ),

            // Star favorite button
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
                    await UserPreferences.removeFavoriteGroup(
                        _group.instanceId, _group.id);
                    showSnackBar(l10n.removed_group_favorites(_group.name));
                  } else {
                    await UserPreferences.addFavoriteGroup(
                        _group.instanceId, _group.id);
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
