import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/SoftButton.dart';
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/GroupCard.dart';
import 'package:krab/models/Group.dart';

class GroupsPage extends StatefulWidget {
  const GroupsPage({super.key});

  @override
  GroupsPageState createState() => GroupsPageState();
}

class GroupsPageState extends State<GroupsPage> with WidgetsBindingObserver {
  // Add a unique key that changes whenever we want to refresh
  Key _refreshKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshData();
    }
  }

  void _refreshData() {
    setState(() {
      _refreshKey = UniqueKey();
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
          Expanded(
            child: FutureBuilder<SupabaseResponse<List<Group>>>(
              key: _refreshKey, // Forces rebuild on refresh
              future: getUserGroups(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                      child: Text(context.l10n.error_loading_groups(snapshot.error.toString())));
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
                  return Center(
                      child: Text(context.l10n.no_group_joined)
                  );
                }
                return ListView.builder(
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    return GroupCard(
                      group: groups[index],
                      onReturn: _refreshData, // Refresh when returning from group
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

/// Join group dialog where the user enters an 8-character group code.
class JoinGroupDialog extends StatefulWidget {
  const JoinGroupDialog({super.key});

  @override
  JoinGroupDialogState createState() => JoinGroupDialogState();
}

class JoinGroupDialogState extends State<JoinGroupDialog> {
  final TextEditingController _controller = TextEditingController();
  String? error;

  Future<void> _joinGroup() async {
    setState(() {
      error = null;
    });
    final code = _controller.text.trim();
    if (code.length != 8) {
      setState(() {
        error = context.l10n.group_code_eight_chars;
      });
      return;
    }
    try {
      final response = await joinGroup(code);
      if (!response.success) {
        setState(() {
          error = context.l10n.group_code_invalid(response.error ?? "Unknown error");
        });
        return;
      }
      Navigator.of(context).pop(true);
      setState(() {});
      showSnackBar(context, context.l10n.group_joined_success, color: Colors.green);
    } catch (e) {
      setState(() {
        error = e.toString();
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
            maxLength: 8,
            hintText: context.l10n.enter_group_code,
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

  Future<void> _createGroup() async {
    setState(() {
      error = null;
    });

    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() {
        error = context.l10n.group_name_empty_error;
      });
      return;
    }

    try {
      final response = await createGroup(name);
      if (!response.success) {
        setState(() {
          error = context.l10n.error_creating_group(response.error ?? "Unknown error");
        });
        return;
      }

      Navigator.of(context).pop(true);
      showSnackBar(context, context.l10n.group_created_success, color: Colors.green);
    } catch (e) {
      setState(() {
        error = e.toString();
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
        SoftButton(
            onPressed: _createGroup,
            label: context.l10n.create,
            color: GlobalThemeData.darkColorScheme.primary
        ),
      ],
    );
  }
}