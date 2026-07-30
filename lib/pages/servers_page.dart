import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/pages/account_page.dart';
import 'package:krab/pages/instance_setup_page.dart';
import 'package:krab/pages/login_page.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/connection_token.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/rectangle_button.dart';

/// Where to send someone who needs a session and hasn't got one.
Widget signInScreen() {
  final registry = InstanceRegistry.instance;
  if (registry.isEmpty) return const InstanceSetupPage();
  final sole = registry.sole;
  return sole == null ? const ServersPage() : LoginPage(instance: sole);
}

/// The servers this install is connected to, and the account held on each.
class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  /// The signed-in user per instance, filled in as they resolve.
  final Map<String, krab_user.User> _users = {};

  /// Instances that could not tell us who the user is.
  final Set<String> _unreachable = {};

  /// Instances still being asked. Kept apart from the two answers so a card is
  /// never showing a verdict before there is one.
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  /// Ask every server whether it is there, and then who it thinks the user is.
  Future<void> _loadUsers() async {
    final all = InstanceRegistry.instance.all;
    final ids = {for (final instance in all) instance.id};

    setState(() {
      _pending.addAll(ids);
      _users.removeWhere((id, _) =>
          !ids.contains(id) ||
          !(InstanceRegistry.instance.byId(id)?.auth.isLoggedIn ?? false));
      _unreachable.removeWhere((id) => !ids.contains(id));
    });

    await Future.wait(all.map((instance) async {
      final reachable = await instance.api.fetchInstanceConfig().orGiveUp();
      if (!mounted) return;

      if (!reachable.success) {
        setState(() {
          _unreachable.add(instance.id);
          _pending.remove(instance.id);
        });
        return;
      }

      _unreachable.remove(instance.id);

      // Answered, and says we have no session.
      if (!instance.auth.isLoggedIn) {
        setState(() => _pending.remove(instance.id));
        return;
      }

      final response = await instance.api.getCurrentUser().orGiveUp();
      if (!mounted) return;
      setState(() {
        _pending.remove(instance.id);
        if (response.success && response.data != null) {
          _users[instance.id] = response.data!;
        } else {
          _unreachable.add(instance.id);
        }
      });
    }));
  }

  /// The server that currently speaks for the user; the highest ranked one that
  /// is signed in and answering.
  String? get _primaryId {
    for (final instance in InstanceRegistry.instance.all) {
      if (_pending.contains(instance.id)) return null;
      if (_users.containsKey(instance.id)) return instance.id;
    }
    return null;
  }

  void _reorder(int oldIndex, int newIndex) {
    final persisted = InstanceRegistry.instance.reorder(oldIndex, newIndex);
    setState(() {});
    unawaited(persisted.then((_) => cacheUserGroupsForWidget()));
  }

  Future<void> _addServer() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const InstanceSetupPage(addingAnother: true),
    ));
    if (!mounted) return;
    setState(() {});
    await _loadUsers();
    unawaited(cacheUserGroupsForWidget());
  }

  Future<void> _signIn(KrabInstance instance) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LoginPage(instance: instance, enterAppOnSuccess: false),
    ));
    if (!mounted) return;
    setState(() {});
    await _loadUsers();
    unawaited(cacheUserGroupsForWidget());
  }

  Future<void> _signOut(KrabInstance instance) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.l10n.servers_sign_out_title,
      message: context.l10n.servers_sign_out_description(instance.label),
      confirmLabel: context.l10n.servers_sign_out,
      confirmIcon: Symbols.logout_rounded,
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    await instance.api.logOut();
    if (!mounted) return;
    setState(() => _users.remove(instance.id));
    unawaited(updateHomeWidget());
  }

  Future<void> _disconnect(KrabInstance instance) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.l10n.servers_disconnect_title,
      message: context.l10n.servers_disconnect_description(instance.label),
      confirmLabel: context.l10n.servers_disconnect,
      confirmIcon: Symbols.link_off_rounded,
      destructive: true,
    );
    if (!confirmed) return;

    // Best-effort: a server that won't answer must still be forgettable.
    if (instance.auth.isLoggedIn) await instance.api.logOut();
    await InstanceRegistry.instance.remove(instance.id);
    if (!mounted) return;

    // Forgetting the last one leaves nothing to show, so go back to connecting.
    if (InstanceRegistry.instance.isEmpty) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const InstanceSetupPage()),
        (route) => false,
      );
      return;
    }

    setState(() => _users.remove(instance.id));
    unawaited(updateHomeWidget());
  }

  /// Hand this server to somebody else, as the connection token the connect
  /// screen understands.
  Future<void> _shareServer(KrabInstance instance) async {
    final token = ConnectionToken.encode(instance.url, instance.anonKey);
    final l10n = context.l10n;
    try {
      await SharePlus.instance.share(ShareParams(
        text: '${l10n.servers_share_subject}\n\n$token',
        subject: l10n.servers_share_subject,
      ));
    } catch (e) {
      debugPrint('Servers: share sheet failed: $e');
      await Clipboard.setData(ClipboardData(text: token));
      if (!mounted) return;
      showSnackBar(context.l10n.servers_token_copied, tone: SnackTone.success);
    }
  }

  Future<void> _openAccount(KrabInstance instance) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AccountPage(instance: instance),
    ));
    if (!mounted) return;
    setState(() {});
    await _loadUsers();
  }

  @override
  Widget build(BuildContext context) {
    final instances = InstanceRegistry.instance.all;
    final primaryId = instances.length > 1 ? _primaryId : null;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.servers_title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text(
              instances.length > 1
                  ? context.l10n.servers_subtitle_ordered
                  : context.l10n.servers_subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              itemCount: instances.length,
              onReorderItem: _reorder,
              buildDefaultDragHandles: false,
              proxyDecorator: (child, index, animation) => Material(
                color: Colors.transparent,
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                child: child,
              ),
              itemBuilder: (context, index) {
                final instance = instances[index];
                return _ServerCard(
                  key: ValueKey(instance.id),
                  index: index,
                  reorderable: instances.length > 1,
                  primary: instance.id == primaryId,
                  instance: instance,
                  user: _users[instance.id],
                  unreachable: _unreachable.contains(instance.id),
                  pending: _pending.contains(instance.id),
                  onSignIn: () => _signIn(instance),
                  onSignOut: () => _signOut(instance),
                  onDisconnect: () => _disconnect(instance),
                  onOpenAccount: () => _openAccount(instance),
                  onShare: () => _shareServer(instance),
                );
              },
            ),
          ),

          // Add server button
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: RectangleButton(
                onPressed: _addServer,
                label: context.l10n.servers_add,
                icon: Symbols.add_rounded,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What each action in a server's menu does.
enum _ServerAction { share, signIn, signOut, disconnect }

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    super.key,
    required this.index,
    required this.reorderable,
    required this.primary,
    required this.instance,
    required this.user,
    required this.unreachable,
    required this.pending,
    required this.onSignIn,
    required this.onSignOut,
    required this.onDisconnect,
    required this.onOpenAccount,
    required this.onShare,
  });

  final int index;
  final bool reorderable;

  /// The server being used as primary right now.
  final bool primary;
  final KrabInstance instance;
  final krab_user.User? user;
  final bool unreachable;

  /// Still waiting on this server, so neither a tick nor a warning is honest yet.
  final bool pending;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback onDisconnect;
  final VoidCallback onOpenAccount;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final signedIn = instance.auth.isLoggedIn;
    final account = user;
    final offerSignIn = !unreachable && !pending;

    final String status;
    if (pending) {
      status = context.l10n.servers_loading;
    } else if (unreachable) {
      status = context.l10n.servers_unreachable;
    } else if (!signedIn) {
      status = context.l10n.servers_not_signed_in;
    } else if (account != null) {
      status = context.l10n.servers_signed_in_as(account.username);
    } else {
      status = '…';
    }

    final Color statusColor;
    if (pending) {
      statusColor = colors.onSurfaceVariant;
    } else if (unreachable) {
      statusColor = colors.error;
    } else {
      statusColor = signedIn ? colors.onSurfaceVariant : colors.tertiary;
    }

    // Still asking: a spinner, since no verdict is honest yet.
    final Widget statusIcon;
    if (pending) {
      statusIcon = SizedBox(
        key: const ValueKey('pending'),
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 2, color: statusColor),
      );
    } else {
      final IconData icon;
      Color color = statusColor;
      if (unreachable) {
        icon = Symbols.warning_rounded;
      } else if (!signedIn) {
        icon = Symbols.error_rounded;
      } else if (account == null) {
        icon = Symbols.warning_rounded;
      } else {
        icon = Symbols.check_circle_rounded;
        color = GlobalThemeData.success;
      }
      statusIcon = Icon(icon,
          key: ValueKey(icon.codePoint), size: 14, fill: 1, color: color);
    }

    return Card(
      key: ValueKey('card-${instance.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: primary
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: colors.primary.withValues(alpha: 0.6), width: 1.5),
            )
          : null,
      child: InkWell(
        onTap: signedIn
            ? onOpenAccount
            : offerSignIn
                ? onSignIn
                : null,
        onLongPress: () => showSnackBar(
          instance.label,
          duration: const Duration(seconds: 3),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              if (reorderable)
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Symbols.drag_indicator_rounded,
                        color: colors.onSurfaceVariant),
                  ),
                ),
              _avatar(context, account, signedIn),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      instance.label,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          letterSpacing: GlobalThemeData.mediumTracking),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            transitionBuilder: (child, animation) =>
                                ScaleTransition(
                              scale: animation,
                              child: FadeTransition(
                                  opacity: animation, child: child),
                            ),
                            child: statusIcon,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            status,
                            style: TextStyle(color: statusColor, fontSize: 13),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _menu(context, signedIn, offerSignIn, colors),
            ],
          ),
        ),
      ),
    );
  }

  /// The account's own picture, so a list of servers reads as a list of the
  /// people you are on them.
  Widget _avatar(BuildContext context, krab_user.User? account, bool signedIn) {
    if (signedIn && account != null) {
      return UserAvatar(account, radius: 22);
    }
    final colors = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 22,
      backgroundColor:
          unreachable ? colors.errorContainer : colors.surfaceContainerHighest,
      child: Icon(
        unreachable ? Symbols.cloud_off_rounded : Symbols.dns_rounded,
        fill: 1,
        color: unreachable ? colors.onErrorContainer : colors.onSurfaceVariant,
      ),
    );
  }

  Widget _menu(BuildContext context, bool signedIn, bool offerSignIn,
      ColorScheme colors) {
    return PopupMenuButton<_ServerAction>(
      icon: Icon(Icons.more_vert_rounded, color: colors.onSurface),
      color: colors.surfaceBright,
      position: PopupMenuPosition.under,
      onSelected: (action) {
        switch (action) {
          case _ServerAction.share:
            onShare();
          case _ServerAction.signIn:
            onSignIn();
          case _ServerAction.signOut:
            onSignOut();
          case _ServerAction.disconnect:
            onDisconnect();
        }
      },
      itemBuilder: (context) => [
        _item(_ServerAction.share, Symbols.share_rounded, context.l10n.share),
        if (signedIn)
          _item(_ServerAction.signOut, Symbols.logout_rounded,
              context.l10n.servers_sign_out)
        else if (offerSignIn)
          _item(_ServerAction.signIn, Symbols.login_rounded,
              context.l10n.servers_sign_in),
        _item(_ServerAction.disconnect, Symbols.link_off_rounded,
            context.l10n.servers_disconnect,
            color: colors.error),
      ],
    );
  }

  PopupMenuItem<_ServerAction> _item(
    _ServerAction value,
    IconData icon,
    String label, {
    Color? color,
  }) =>
      PopupMenuItem(
        value: value,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: color),
          title: Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w400)),
        ),
      );
}
