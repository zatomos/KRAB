import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/models/group_invite.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/l10n/l10n.dart';

/// Management view to create, share, and revoke group invites.
class GroupInvitesPage extends StatefulWidget {
  final String groupId;

  const GroupInvitesPage({super.key, required this.groupId});

  @override
  State<GroupInvitesPage> createState() => _GroupInvitesPageState();
}

class _GroupInvitesPageState extends State<GroupInvitesPage> {
  late Future<SupabaseResponse<List<GroupInvite>>> _invitesFuture;

  @override
  void initState() {
    super.initState();
    _invitesFuture = listGroupInvites(widget.groupId);
  }

  void _refresh() {
    setState(() => _invitesFuture = listGroupInvites(widget.groupId));
  }

  Future<void> _createInvite() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => CreateInviteDialog(groupId: widget.groupId),
    );
    if (token == null || !mounted) return;
    await showInviteTokenDialog(context, token);
    _refresh();
  }

  Future<void> _revokeInvite(String token) async {
    final confirm = await showConfirmDialog(context,
        title: context.l10n.revoke_invite,
        message: context.l10n.revoke_invite_confirmation,
        confirmLabel: context.l10n.revoke,
        destructive: true);
    if (!confirm) return;

    final res = await revokeGroupInvite(token);
    if (!mounted) return;
    if (res.success) {
      showSnackBar(context.l10n.invite_revoked_success,
          tone: SnackTone.success);
      _refresh();
    } else {
      showSnackBar(context.errorText(res.error), tone: SnackTone.failure);
    }
  }

  void _copyToken(String token) {
    Clipboard.setData(ClipboardData(text: token));
    showSnackBar(context.l10n.invite_copied, tone: SnackTone.success);
  }

  String _subtitleFor(BuildContext context, GroupInvite invite) {
    final parts = <String>[];
    parts.add(invite.maxUses == null
        ? context.l10n.invite_uses_unlimited(invite.uses)
        : context.l10n.invite_uses_limited(invite.uses, invite.maxUses!));
    if (invite.expiresAt != null) {
      final d = invite.expiresAt!.toLocal();
      parts.add(context.l10n.invite_expires(
          "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}"));
    }
    if (!invite.isActive) parts.add(context.l10n.invite_inactive);
    return parts.join(" · ");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.manage_invites)),
      floatingActionButton: SoftButton(
          onPressed: _createInvite,
          icon: Symbols.add_link_rounded,
          label: context.l10n.create_invite,
          color: Theme.of(context).colorScheme.primary),
      body: FutureBuilder<SupabaseResponse<List<GroupInvite>>>(
        future: _invitesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.data!.success) {
            return Center(child: Text(context.errorText(snapshot.data!.error)));
          }
          final invites = snapshot.data!.data ?? [];
          if (invites.isEmpty) {
            return Center(child: Text(context.l10n.no_invites));
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: invites.length,
            itemBuilder: (context, index) {
              final invite = invites[index];
              return ListTile(
                leading: Icon(
                  invite.isActive
                      ? Symbols.link_rounded
                      : Symbols.link_off_rounded,
                  color: invite.isActive
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  invite.token,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                subtitle: Text(_subtitleFor(context, invite)),
                onTap: () => _copyToken(invite.token),
                trailing: invite.isActive
                    ? IconButton(
                        icon: const Icon(Symbols.delete_rounded,
                            color: Colors.red),
                        tooltip: context.l10n.revoke,
                        onPressed: () => _revokeInvite(invite.token),
                      )
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}

/// Dialog to create a new invite with an expiry and max-uses selection
class CreateInviteDialog extends StatefulWidget {
  final String groupId;

  const CreateInviteDialog({super.key, required this.groupId});

  @override
  State<CreateInviteDialog> createState() => _CreateInviteDialogState();
}

class _CreateInviteDialogState extends State<CreateInviteDialog> {
  // null Duration -> never expires
  Duration? _expiry = const Duration(days: 1);
  // null means -> no limit
  int? _maxUses;
  String? error;
  bool _loading = false;

  Future<void> _create() async {
    if (_loading) return;
    setState(() {
      error = null;
      _loading = true;
    });

    final expiresAt = _expiry == null ? null : DateTime.now().add(_expiry!);
    final res = await createGroupInvite(widget.groupId,
        expiresAt: expiresAt, maxUses: _maxUses);
    if (!mounted) return;
    if (!res.success) {
      setState(() {
        error = context.errorText(res.error);
        _loading = false;
      });
      return;
    }
    Navigator.of(context).pop(res.data);
  }

  // null means -> never expires.
  static const List<Duration?> _expiryDurations = [
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 6),
    Duration(hours: 12),
    Duration(days: 1),
    Duration(days: 7),
    null,
  ];

  String _durationLabel(BuildContext context, Duration? d) {
    if (d == null) return context.l10n.duration_never;
    if (d.inMinutes < 60) return context.l10n.duration_minutes(d.inMinutes);
    if (d.inHours < 24) return context.l10n.duration_hours(d.inHours);
    return context.l10n.duration_days(d.inDays);
  }

  @override
  Widget build(BuildContext context) {
    final expiryOptions = _expiryDurations
        .map((d) => DropdownMenuItem<Duration?>(
            value: d, child: Text(_durationLabel(context, d))))
        .toList();

    final maxUsesOptions = <DropdownMenuItem<int?>>[
      for (final n in [1, 5, 10, 15, 25, 50])
        DropdownMenuItem(value: n, child: Text('$n')),
      DropdownMenuItem(value: null, child: Text(context.l10n.no_limit)),
    ];

    return AlertDialog(
      title: Text(context.l10n.create_invite),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.expires_after),
          DropdownButton<Duration?>(
            isExpanded: true,
            value: _expiry,
            items: expiryOptions,
            onChanged: (v) => setState(() => _expiry = v),
          ),
          const SizedBox(height: 16),
          Text(context.l10n.max_uses_label),
          DropdownButton<int?>(
            isExpanded: true,
            value: _maxUses,
            items: maxUsesOptions,
            onChanged: (v) => setState(() => _maxUses = v),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
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
              child: CircularProgressIndicator(strokeWidth: 2))
        else
          SoftButton(
            onPressed: _create,
            label: context.l10n.create_invite,
            color: Theme.of(context).colorScheme.primary,
          ),
      ],
    );
  }
}

/// Shows a freshly created invite token with a copy button
Future<void> showInviteTokenDialog(BuildContext context, String token) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.invite_created),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(context.l10n.invite_share_hint),
          const SizedBox(height: 12),
          SelectableText(
            token,
            style: const TextStyle(
                fontFamily: 'monospace', fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(context).pop(),
          label: context.l10n.close,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        SoftButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: token));
            showSnackBar(context.l10n.invite_copied, tone: SnackTone.success);
            Navigator.of(context).pop();
          },
          label: context.l10n.copy,
          color: Theme.of(context).colorScheme.primary,
        ),
      ],
    ),
  );
}
