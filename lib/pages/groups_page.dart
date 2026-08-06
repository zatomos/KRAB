import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/widgets/delayed_loading.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/group_card.dart';
import 'package:krab/widgets/instance_status_footer.dart';
import 'package:krab/pages/image_feed_page.dart';
import 'package:krab/models/group.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/invite_token.dart';
import 'package:krab/services/instance/instance_registry.dart';

class GroupsPage extends StatefulWidget {
  /// Route name used so a group gallery's back button can return
  /// straight to the group list, wherever it was opened from.
  static const String routeName = 'groups';

  const GroupsPage({super.key});

  @override
  GroupsPageState createState() => GroupsPageState();
}

class GroupsPageState extends State<GroupsPage> {
  /// Every server's groups, added to as each server answers.
  final List<Group> _groups = [];

  /// Member counts, fetched before a server's cards are shown so they arrive
  /// complete.
  final Map<String, int> _counts = {};

  /// Servers that could not be asked, named under the list.
  List<KrabInstance> _unavailable = const [];

  /// Servers not heard from yet, so the footer can say it is waiting rather than
  /// declaring what already failed.
  List<KrabInstance> _pending = const [];

  /// True until the first server has answered, one way or the other.
  bool _loading = true;

  /// Set when every server failed, which is the only case worth an error.
  bool _allFailed = false;

  /// Guards against a reload's results landing on top of a newer one.
  int _load = 0;

  /// How long a server's groups wait on their member counts before being shown
  /// without them.
  static const Duration _countGrace = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  void _refreshData() {
    setState(() {
      _groups.clear();
      _counts.clear();
      _unavailable = const [];
      _pending = const [];
      _loading = true;
      _allFailed = false;
    });
    _loadGroups();
  }

  /// Ask every signed-in server for the user's groups, showing each server's as
  /// it answers.
  Future<void> _loadGroups() async {
    final load = ++_load;
    final sources = InstanceRegistry.instance.all;
    if (sources.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final failed = <KrabInstance>[];
    final waiting = List<KrabInstance>.of(sources);
    setState(() => _pending = List.of(waiting));

    await Future.wait(sources.map((instance) async {
      final response = await instance.api.getUserGroups().orGiveUp();
      if (!mounted || load != _load) return;

      if (!response.success || response.data == null) {
        debugPrint('Groups: ${instance.id} failed (${response.error})');
        waiting.remove(instance);
        failed.add(instance);
        setState(() {
          _unavailable = List.of(failed);
          _pending = List.of(waiting);
          _loading = false;
          _allFailed = failed.length == sources.length;
        });
        return;
      }

      final counting = _loadCounts(instance, response.data!, load);
      await counting.timeout(_countGrace, onTimeout: () {});
      if (!mounted || load != _load) return;

      waiting.remove(instance);
      setState(() {
        _groups.addAll(response.data!);
        _sortGroups();
        _pending = List.of(waiting);
        _loading = false;
      });
    }));
  }

  /// Newest activity first.
  void _sortGroups() {
    _groups.sort((a, b) {
      final aAt = a.latestImageAt;
      final bAt = b.latestImageAt;
      if (aAt == null && bAt == null) return a.name.compareTo(b.name);
      if (aAt == null) return 1;
      if (bAt == null) return -1;
      return bAt.compareTo(aAt);
    });
  }

  Future<void> _loadCounts(
      KrabInstance instance, List<Group> groups, int load) async {
    await Future.wait(groups.map((group) async {
      final res = await instance.api.getGroupMemberCount(group.id).orGiveUp();
      if (!mounted || load != _load) return;
      setState(() => _counts['${group.instanceId}/${group.id}'] =
          res.error == null ? (res.data ?? 0) : 0);
    }));
  }

  /// Open one of the menu's dialogs, and reload the list if it changed one.
  Future<void> _openDialog(Widget dialog) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => dialog,
    );
    if (changed == true && mounted) _refreshData();
  }

  PopupMenuItem<Widget> _menuItem(IconData icon, String label, Widget dialog) {
    return PopupMenuItem(
      value: dialog,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w400)),
      ),
    );
  }

  Widget _buildGroupsContent(BuildContext context) {
    final groups = _groups;

    // Nothing came back from anywhere, and the footer alone would leave an empty
    // screen with no explanation in it.
    if (groups.isEmpty && _allFailed) {
      return Center(child: Text(context.l10n.failed_to_load_groups));
    }
    if (groups.isEmpty) {
      return Center(child: Text(context.l10n.no_group_joined));
    }

    final counts = _counts;
    final showOrigin = InstanceRegistry.instance.all.length > 1;

    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return GroupCard(
          group: group,
          memberCount: counts['${group.instanceId}/${group.id}'],
          showOrigin: showOrigin,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.your_groups_page_title),
        actions: [
          PopupMenuButton<Widget>(
            icon: const Icon(Icons.more_vert_rounded),
            color: Theme.of(context).colorScheme.surfaceContainer,
            position: PopupMenuPosition.under,
            onSelected: _openDialog,
            itemBuilder: (context) => [
              _menuItem(Symbols.group_add_rounded,
                  context.l10n.create_new_group, const CreateGroupDialog()),
              _menuItem(Symbols.groups_rounded, context.l10n.join_group,
                  const JoinGroupDialog()),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _RecentPhotosCard(),
          Expanded(
            child: DelayedLoading(
              loading: _loading,
              placeholder: const _GroupsSkeleton(),
              child: _buildGroupsContent(context),
            ),
          ),
          InstanceStatusFooter(
            pending: _pending,
            unavailable: _unavailable,
            failure: (servers) =>
                context.l10n.groups_server_unavailable(servers),
          ),
        ],
      ),
    );
  }
}

/// Names the servers whose groups are missing from the list above it.

/// Bone placeholders
class _GroupsSkeleton extends StatelessWidget {
  const _GroupsSkeleton();

  static const int _rowCount = 5;

  @override
  Widget build(BuildContext context) {
    return Skeletonizer.zone(
      child: ListView(
        children: List.generate(
          _rowCount,
          (_) => const Card(
            margin: EdgeInsets.symmetric(horizontal: 0, vertical: 8),
            elevation: 0,
            child: ListTile(
              contentPadding: EdgeInsets.fromLTRB(15, 2, 5, 2),
              minVerticalPadding: 0,
              visualDensity: VisualDensity.compact,
              leading: Bone.circle(size: 50),
              title: Bone.text(width: 140),
              subtitle: Bone.text(width: 80),
            ),
          ),
        ),
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
      color: scheme.surfaceContainer,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(15, 2, 15, 2),
        minVerticalPadding: 0,
        visualDensity: VisualDensity.compact,
        leading: CircleAvatar(
          radius: 25,
          backgroundColor: scheme.primary,
          child: const Icon(Symbols.photo_library,
              fill: 1, color: GlobalThemeData.onAccent),
        ),
        title: Text(
          context.l10n.recent_photos,
          style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: GlobalThemeData.mediumTracking),
        ),
        subtitle: Text(
          context.l10n.recent_photos_subtitle,
          style: TextStyle(fontSize: 14, color: scheme.muted),
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
      onSubmit: (token, instance) async {
        final res =
            await instance.api.joinGroupByInvite(extractInviteToken(token));
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
  final Future<String?> Function(String value, KrabInstance instance) onSubmit;

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

  late final List<KrabInstance> _targets =
      InstanceRegistry.instance.all.where((i) => i.auth.isLoggedIn).toList();

  late KrabInstance? _target = _targets.length == 1 ? _targets.first : null;

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

    final target = _target;
    if (target == null) {
      setState(() {
        _error = context.l10n.servers_pick_one;
        _loading = false;
      });
      return;
    }

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
      error = await widget.onSubmit(value, target);
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
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.title),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RoundedInputField(
              controller: _controller,
              hintText: widget.hintText,
              errorText: _error,
              maxLength: widget.maxLength,
            ),
            if (_targets.length > 1) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<KrabInstance>(
                initialValue: _target,
                hint: Text(context.l10n.servers_pick_one),
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.l10n.server_label,
                  prefixIcon: const Icon(Symbols.dns_rounded),
                ),
                items: [
                  for (final instance in _targets)
                    DropdownMenuItem(
                      value: instance,
                      child:
                          Text(instance.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (picked) {
                  if (picked != null) setState(() => _target = picked);
                },
              ),
            ],
          ],
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
      onSubmit: (name, instance) async {
        final res = await instance.api.createGroup(name);
        return res.success
            ? null
            : l10n.error_creating_group(res.error ?? l10n.unknown_error);
      },
    );
  }
}
