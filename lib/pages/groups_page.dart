import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/group_card.dart';
import 'package:krab/pages/image_feed_page.dart';
import 'package:krab/models/group.dart';

class GroupsPage extends StatefulWidget {
  /// Route name used so a group gallery's back button can return
  /// straight to the group list, wherever it was opened from.
  static const String routeName = 'groups';

  const GroupsPage({super.key});

  @override
  GroupsPageState createState() => GroupsPageState();
}

class GroupsPageState extends State<GroupsPage> {
  late Future<SupabaseResponse<List<Group>>> _groupsFuture;

  @override
  void initState() {
    super.initState();
    _groupsFuture = getUserGroups();
  }

  void _refreshData() {
    setState(() {
      _groupsFuture = getUserGroups();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.your_groups_page_title),
        actions: [
          IconButton(
              icon: const Icon(Icons.more_vert_rounded),
              onPressed: () {
                showMenu(
                  context: context,
                  color: GlobalThemeData.darkColorScheme.surfaceBright,
                  position: const RelativeRect.fromLTRB(0, 90, -1, 0),
                  items: [
                    PopupMenuItem(
                      child: ListTile(
                        leading: const Icon(Symbols.group_add_rounded),
                        title: Text(context.l10n.create_new_group),
                        onTap: () {
                          Navigator.pop(context);
                          showDialog(
                            context: context,
                            builder: (context) => const CreateGroupDialog(),
                          ).then((value) {
                            if (value == true) {
                              _refreshData();
                            }
                          });
                        },
                      ),
                    ),
                    PopupMenuItem(
                      child: ListTile(
                        leading: const Icon(Symbols.groups_rounded),
                        title: Text(context.l10n.join_group),
                        onTap: () {
                          Navigator.pop(context);
                          showDialog(
                            context: context,
                            builder: (context) => const JoinGroupDialog(),
                          ).then((value) {
                            if (value == true) {
                              _refreshData();
                            }
                          });
                        },
                      ),
                    ),
                  ],
                );
              }),
        ],
      ),
      body: Column(
        children: [
          _RecentPhotosCard(),
          Expanded(
            child: FutureBuilder<SupabaseResponse<List<Group>>>(
              future: _groupsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                      child: Text(context.l10n
                          .error_loading_groups(snapshot.error.toString())));
                }
                if (!snapshot.hasData) {
                  return const Center(child: Text("No groups data available."));
                }
                final response = snapshot.data!;
                if (!response.success) {
                  return Center(child: Text("Error: ${response.error}"));
                }
                final groups = response.data ?? [];
                if (groups.isEmpty) {
                  return Center(child: Text(context.l10n.no_group_joined));
                }
                return ListView.builder(
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    return GroupCard(
                      group: groups[index],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Pinned card opening the cross-group gallery of recent photos
class _RecentPhotosCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = GlobalThemeData.darkColorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 0,
      color: scheme.surfaceBright,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(15, 2, 15, 2),
        minVerticalPadding: 0,
        visualDensity: VisualDensity.compact,
        leading: CircleAvatar(
          radius: 25,
          backgroundColor: scheme.primary,
          child: Icon(Symbols.photo_library,
              fill: 1, color: scheme.onPrimary),
        ),
        title: Text(
          context.l10n.recent_photos,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          context.l10n.recent_photos_subtitle,
          style: const TextStyle(fontSize: 14, color: Colors.grey),
        ),
        trailing: const Icon(Symbols.chevron_right_rounded),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ImageFeedPage()),
        ),
      ),
    );
  }
}

/// Join group dialog where the user pastes an invite token.
class JoinGroupDialog extends StatefulWidget {
  const JoinGroupDialog({super.key});

  @override
  JoinGroupDialogState createState() => JoinGroupDialogState();
}

class JoinGroupDialogState extends State<JoinGroupDialog> {
  final TextEditingController _controller = TextEditingController();
  String? error;
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _joinGroup() async {
    if (_loading) return;
    setState(() {
      error = null;
      _loading = true;
    });
    final token = _controller.text.trim();
    if (token.isEmpty) {
      setState(() {
        error = context.l10n.invite_empty;
        _loading = false;
      });
      return;
    }
    try {
      final response = await joinGroupByInvite(token);
      if (!mounted) return;
      if (!response.success) {
        setState(() {
          error = context.l10n
              .group_code_invalid(context.errorOr(response.error));
          _loading = false;
        });
        return;
      }
      cacheUserGroupsForWidget();
      Navigator.of(context).pop(true);
      showSnackBar(context.l10n.group_joined_success, color: Colors.green);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.join_group),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RoundedInputField(
            controller: _controller,
            hintText: context.l10n.enter_invite,
            errorText: error,
          ),
        ],
      ),
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(context).pop(),
          label: context.l10n.cancel,
          color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
        ),
        if (_loading)
          const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
        else
          SoftButton(
            onPressed: _joinGroup,
            label: context.l10n.join,
            color: GlobalThemeData.darkColorScheme.primary,
          ),
      ],
    );
  }
}

/// Create group dialog where the user enters a group name.
class CreateGroupDialog extends StatefulWidget {
  const CreateGroupDialog({super.key});

  @override
  CreateGroupDialogState createState() => CreateGroupDialogState();
}

class CreateGroupDialogState extends State<CreateGroupDialog> {
  final TextEditingController _controller = TextEditingController();
  String? error;
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    if (_loading) return;
    setState(() {
      error = null;
      _loading = true;
    });

    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() {
        error = context.l10n.group_name_empty_error;
        _loading = false;
      });
      return;
    }

    try {
      final response = await createGroup(name);
      if (!mounted) return;
      if (!response.success) {
        setState(() {
          error = context.l10n
              .error_creating_group(context.errorOr(response.error));
          _loading = false;
        });
        return;
      }

      cacheUserGroupsForWidget();
      Navigator.of(context).pop(true);
      showSnackBar(context.l10n.group_created_success, color: Colors.green);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.create_group),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RoundedInputField(
            controller: _controller,
            hintText: context.l10n.enter_group_name,
            errorText: error,
          ),
        ],
      ),
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(context).pop(),
          label: context.l10n.cancel,
          color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
        ),
        if (_loading)
          const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
        else
          SoftButton(
            onPressed: _createGroup,
            label: context.l10n.create,
            color: GlobalThemeData.darkColorScheme.primary,
          ),
      ],
    );
  }
}
