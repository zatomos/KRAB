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

  /// A menu entry that opens a dialog, and reloads the list if it changed one.
  PopupMenuItem<void> _menuItem(IconData icon, String label, Widget dialog) {
    return PopupMenuItem(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        onTap: () async {
          Navigator.pop(context);
          final changed = await showDialog<bool>(
            context: context,
            builder: (_) => dialog,
          );
          if (changed == true && mounted) _refreshData();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.your_groups_page_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () => showMenu(
              context: context,
              color: Theme.of(context).colorScheme.surfaceBright,
              position: const RelativeRect.fromLTRB(0, 100, -1, 0),
              items: [
                _menuItem(Symbols.group_add_rounded,
                    context.l10n.create_new_group, const CreateGroupDialog()),
                _menuItem(Symbols.groups_rounded, context.l10n.join_group,
                    const JoinGroupDialog()),
              ],
            ),
          ),
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
                if (snapshot.hasError || !snapshot.hasData) {
                  debugPrint("Failed to load groups: ${snapshot.error}");
                  return Center(
                      child: Text(context.l10n.failed_to_load_groups));
                }
                final response = snapshot.data!;
                if (!response.success) {
                  debugPrint("Failed to load groups: ${response.error}");
                  return Center(
                      child: Text(context.l10n.failed_to_load_groups));
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
    final scheme = Theme.of(context).colorScheme;
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
          child: Icon(Symbols.photo_library, fill: 1, color: scheme.onPrimary),
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
class JoinGroupDialog extends StatelessWidget {
  const JoinGroupDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _GroupFormDialog(
      title: l10n.join_group,
      hintText: l10n.enter_invite,
      emptyError: l10n.invite_empty,
      submitLabel: l10n.join,
      submitIcon: Symbols.groups_rounded,
      successMessage: l10n.group_joined_success,
      onSubmit: (token) async {
        final res = await joinGroupByInvite(token);
        return res.success
            ? null
            : l10n.group_code_invalid(res.error ?? l10n.unknown_error);
      },
    );
  }
}

/// One text field and a submit button, for the actions that add a group to the
/// user's list. Pops true once the group list has changed.
class _GroupFormDialog extends StatefulWidget {
  final String title;
  final String hintText;
  final String emptyError;
  final String submitLabel;
  final IconData submitIcon;
  final String successMessage;
  final int? maxLength;

  /// Returns null on success, or the message to show under the field.
  final Future<String?> Function(String value) onSubmit;

  const _GroupFormDialog({
    required this.title,
    required this.hintText,
    required this.emptyError,
    required this.submitLabel,
    required this.submitIcon,
    required this.successMessage,
    required this.onSubmit,
    this.maxLength,
  });

  @override
  State<_GroupFormDialog> createState() => _GroupFormDialogState();
}

class _GroupFormDialogState extends State<_GroupFormDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    setState(() {
      _error = null;
      _loading = true;
    });

    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() {
        _error = widget.emptyError;
        _loading = false;
      });
      return;
    }

    String? error;
    try {
      error = await widget.onSubmit(value);
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;

    if (error != null) {
      setState(() {
        _error = error;
        _loading = false;
      });
      return;
    }

    cacheUserGroupsForWidget();
    Navigator.of(context).pop(true);
    showSnackBar(widget.successMessage, tone: SnackTone.success);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: RoundedInputField(
          controller: _controller,
          hintText: widget.hintText,
          errorText: _error,
          maxLength: widget.maxLength,
        ),
      ),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(context).pop(),
          label: context.l10n.cancel,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        if (_loading)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          SoftButton(
            onPressed: _submit,
            label: widget.submitLabel,
            icon: widget.submitIcon,
            color: Theme.of(context).colorScheme.primary,
          ),
      ],
    );
  }
}

/// Create group dialog where the user enters a group name.
class CreateGroupDialog extends StatelessWidget {
  const CreateGroupDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _GroupFormDialog(
      title: l10n.create_group,
      hintText: l10n.enter_group_name,
      emptyError: l10n.group_name_empty_error,
      submitLabel: l10n.create,
      submitIcon: Symbols.group_add_rounded,
      successMessage: l10n.group_created_success,
      maxLength: 19,
      onSubmit: (name) async {
        final res = await createGroup(name);
        return res.success
            ? null
            : l10n.error_creating_group(res.error ?? l10n.unknown_error);
      },
    );
  }
}
