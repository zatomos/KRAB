import 'package:flutter/material.dart';
import 'package:qr_bar_code/qr/src/qr_code.dart';

import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/RectangleButton.dart';
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/models/Group.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/UserPreferences.dart';

class GroupSettingsPage extends StatefulWidget {
  final Group group;
  final bool isAdmin;

  const GroupSettingsPage(
      {super.key, required this.group, this.isAdmin = false});

  @override
  GroupSettingsPageState createState() => GroupSettingsPageState();
}

class GroupSettingsPageState extends State<GroupSettingsPage> {
  late Future<SupabaseResponse<List<dynamic>>> _membersFuture;

  @override
  void initState() {
    super.initState();
    _membersFuture = getGroupMembers(widget.group.id);
  }

  Future<void> _leaveGroup() async {
    await UserPreferences.removeFavoriteGroup(widget.group.id);
    final response = await leaveGroup(widget.group.id);
    if (response.success) {
      showSnackBar(context, "Left group successfully.", color: Colors.green);
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      showSnackBar(context, "Failed to leave group: ${response.error}",
          color: Colors.red);
    }
  }

  Future<void> _updateGroupName() async {
    TextEditingController controller = TextEditingController();
    bool error = false;
    String errorMessage = "";

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text("Edit Group Name"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RoundedInputField(
                    controller: controller,
                    hintText: "New group name",
                  ),
                  if (error)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                        errorMessage,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("Cancel"),
                ),
                TextButton(
                  onPressed: () async {
                    // Validate input
                    if (controller.text.trim().isEmpty) {
                      setState(() {
                        error = true;
                        errorMessage = "Group name cannot be empty";
                      });
                      return;
                    }

                    // Attempt to update the group name
                    final response = await updateGroupName(
                        widget.group.id, controller.text.trim());

                    // Check if the response contains an error
                    if (!response.success) {
                      setState(() {
                        error = true;
                        errorMessage =
                            "Failed to update group name: ${response.error}";
                      });
                    } else {
                      Navigator.of(context)
                          .pop();
                      showSnackBar(context, "Group name updated successfully.",
                          color: Colors.green);
                    }
                  },
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _deleteGroup() async {
    bool confirm = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text("Delete Group"),
              content:
                  const Text("Are you sure you want to delete this group?"),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text("Cancel"),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text("Delete"),
                ),
              ],
            );
          },
        ) ??
        false;

    if (confirm) {
      await UserPreferences.removeFavoriteGroup(widget.group.id);
      final response = await deleteGroup(widget.group.id);
      if (response.success) {
        showSnackBar(context, "Group deleted successfully.",
            color: Colors.green);
        Navigator.of(context).popUntil((route) => route.isFirst);
      } else {
        showSnackBar(context, "Failed to delete group: ${response.error}",
            color: Colors.red);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Group Settings"), actions: [
        IconButton(
          icon: const Icon(Icons.edit),
          onPressed: () {
            _updateGroupName();
          },
        ),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            // Centered Section
            Center(
              child: Column(
                children: [
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius:
                            BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.all(2),
                      child: QRCode(
                        data: widget.group.code.toUpperCase(),
                        size: MediaQuery.of(context).size.width * 0.5,
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "Group Code: ${widget.group.code.toUpperCase()}",
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            const Text(
              "Members",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            // Members List
            Expanded(
              child: FutureBuilder<SupabaseResponse<List<dynamic>>>(
                future: _membersFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  } else if (snapshot.hasError) {
                    return Center(child: Text("Error: ${snapshot.error}"));
                  } else {
                    final members = snapshot.data!.data!;
                    if (members.isEmpty) {
                      return const Center(child: Text("No members found."));
                    }
                    return ListView.builder(
                      itemCount: members.length,
                      itemBuilder: (context, index) {
                        final member = members[index];
                        return ListTile(
                          leading: const Icon(Icons.person),
                          title: Text(member['username'] ?? 'Unknown'),
                        );
                      },
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 16),

            // Leave/Delete Buttons
            Center(
              child: Column(
                children: [
                  RectangleButton(
                    onPressed: _leaveGroup,
                    label: 'Leave Group',
                    backgroundColor: Colors.red,
                  ),
                  if (widget.isAdmin) const SizedBox(height: 16),
                  if (widget.isAdmin)
                    RectangleButton(
                      onPressed: _deleteGroup,
                      label: 'Delete Group',
                      backgroundColor: Colors.red,
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
