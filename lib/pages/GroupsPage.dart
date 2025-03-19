import 'package:flutter/material.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/GroupCard.dart';
import 'package:krab/models/Group.dart';

class GroupsPage extends StatefulWidget {
  const GroupsPage({super.key});

  @override
  GroupsPageState createState() => GroupsPageState();
}

class GroupsPageState extends State<GroupsPage> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    debugPrint("GroupsPageState.didChangeDependencies");
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Your Groups"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {});
            },
          ),
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
                        leading: const Icon(Icons.group_add_rounded),
                        title: const Text("Create New Group"),
                        onTap: () {
                          Navigator.pop(context);
                          showDialog(
                            context: context,
                            builder: (context) => const CreateGroupDialog(),
                          ).then((value) {
                            if (value == true) {
                              setState(() {});
                            }
                          });
                        },
                      ),
                    ),
                    PopupMenuItem(
                      child: ListTile(
                        leading: const Icon(Icons.groups_2_rounded),
                        title: const Text("Join Group"),
                        onTap: () {
                          Navigator.pop(context);
                          showDialog(
                            context: context,
                            builder: (context) => const JoinGroupDialog(),
                          ).then((value) {
                            setState(() {});
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
              future:
                  getUserGroups(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                      child: Text("Error loading groups: ${snapshot.error}"));
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
                  return const Center(
                    child: Text("You haven't joined any groups yet."),
                  );
                }
                return ListView.builder(
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    return GroupCard(group: groups[index]);
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
  bool isLoading = false;

  Future<void> _joinGroup() async {
    setState(() {
      error = null;
    });
    final code = _controller.text.trim();
    if (code.length != 8) {
      setState(() {
        error = "Group code must be exactly 8 characters.";
      });
      return;
    }
    setState(() {
      isLoading = true;
    });
    try {
      final response = await joinGroup(code);
      if (!response.success) {
        setState(() {
          error = "Invalid group code: ${response.error}";
        });
        return;
      }
      Navigator.of(context).pop(true);
      setState(() {});
      showSnackBar(context, "Successfully joined group!", color: Colors.green);
    } catch (e) {
      setState(() {
        error = e.toString();
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Join Group"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            maxLength: 8,
            decoration: InputDecoration(
              labelText: "Enter Group Code",
              errorText: error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: isLoading ? null : _joinGroup,
          child: isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text("Join"),
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
  bool isLoading = false;

  Future<void> _createGroup() async {
    setState(() {
      error = null;
    });

    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() {
        error = "Group name cannot be empty.";
      });
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final response = await createGroup(name);
      if (!response.success) {
        setState(() {
          error = "Error creating group: ${response.error}";
        });
        return;
      }

      Navigator.of(context).pop(true);
      showSnackBar(context, "Group created successfully.", color: Colors.green);
    } catch (e) {
      setState(() {
        error = e.toString();
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Create Group"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: "Enter Group Name",
              errorText: error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: isLoading ? null : _createGroup,
          child: isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text("Create"),
        ),
      ],
    );
  }
}
