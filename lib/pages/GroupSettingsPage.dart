import 'package:flutter/material.dart';
import 'package:qr_bar_code/qr/src/qr_code.dart';

import 'package:krab/l10n/l10n.dart';
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
      showSnackBar(context, context.l10n.left_group_success,
          color: Colors.green);
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      showSnackBar(
          context, context.l10n.error_leaving_group(response.error ?? "Unknown error"),
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
              title: Text(context.l10n.edit_group_name),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RoundedInputField(
                      controller: controller,
                      hintText: context.l10n.new_group_name),
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
                    child: Text(context.l10n.cancel)),
                TextButton(
                    onPressed: () async {
                      // Validate input
                      if (controller.text.trim().isEmpty) {
                        setState(() {
                          error = true;
                          errorMessage = context.l10n.group_name_empty;
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
                          errorMessage = context.l10n.error_updating_group_name(
                              response.error.toString());
                        });
                      } else {
                        Navigator.of(context).pop();
                        showSnackBar(
                            context, context.l10n.group_name_updated_success,
                            color: Colors.green);
                      }
                    },
                    child: Text(context.l10n.save)),
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
              title: Text(context.l10n.delete_group),
              content: Text(context.l10n.delete_group_confirmation),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(context.l10n.cancel)),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(context.l10n.delete)),
              ],
            );
          },
        ) ??
        false;

    if (confirm) {
      await UserPreferences.removeFavoriteGroup(widget.group.id);
      final response = await deleteGroup(widget.group.id);
      if (response.success) {
        showSnackBar(context, context.l10n.group_deleted_success,
            color: Colors.green);
        Navigator.of(context).popUntil((route) => route.isFirst);
      } else {
        showSnackBar(context,
            context.l10n.error_deleting_group(response.error ?? "Unknown error"),
            color: Colors.red);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(title: Text(context.l10n.group_settings_page_title), actions: [
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Centered Section
            Center(
              child: Column(
                children: [
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
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
                    context.l10n.group_code(widget.group.code.toUpperCase()),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            Text(
              context.l10n.members,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                      return Center(child: Text(context.l10n.no_members));
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
                    label: context.l10n.leave_group,
                    backgroundColor: Colors.red,
                  ),
                  if (widget.isAdmin) const SizedBox(height: 16),
                  if (widget.isAdmin)
                    RectangleButton(
                      onPressed: _deleteGroup,
                      label: context.l10n.delete_group,
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
