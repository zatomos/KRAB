import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:krab/services/auth/app_auth.dart';
import 'package:intl/intl.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/group.dart';
import 'package:krab/pages/image_feed_page.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/services/file_saver.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/widgets/comments_bottom_sheet.dart';
import 'package:krab/widgets/dialogs/add_to_groups_dialog.dart';
import 'package:krab/widgets/dialogs/delete_image_dialog.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/reactions_bar.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/themes/global_theme_data.dart';

final Map<String, List<Group>> _postedInGroupsCache = {};

Future<List<Group>?> fetchPostedInGroups(String imageId) async {
  final cached = _postedInGroupsCache[imageId];
  if (cached != null) return cached;

  final response = await getImageGroups(imageId);
  if (!response.success || response.data == null) return null;

  final groups = await Future.wait((response.data!).map((e) async {
    final map = e as Map<String, dynamic>;
    final id = map['group_id']?.toString() ?? '';
    return Group(
      id: id,
      name: map['group_name']?.toString() ?? '',
      iconUrl: await resolveGroupIconUrl(id),
      createdAt: '',
    );
  }));

  _postedInGroupsCache[imageId] = groups;
  return groups;
}

/// Forget an image's cached groups so the next fetch reflects a change (e.g.
/// after the photo is removed from some of them).
void invalidatePostedInGroups(String imageId) {
  _postedInGroupsCache.remove(imageId);
}

/// Actions offered by the viewer's overflow menu.
enum _ViewerAction { save, addToGroups, delete }

/// The non-zoomable chrome layered over the current photo in the gallery.
class ViewerOverlay extends StatefulWidget {
  final String imageId;

  /// The group the image was opened from, or null in the cross-group
  /// "recent photos" gallery where comments span every shared group
  final String? groupId;
  final ImageData imageData;
  final krab_user.User uploader;
  final int commentCount;

  /// When this image was posted to the group it was opened from.
  /// Null in the cross-group feed or when unknown, in which case
  /// the displayed date falls back to the image's own creation time.
  final DateTime? uploadedAt;

  /// Returns the best available bytes (full-res if loaded, else low-res) to
  /// save to the gallery.
  final Future<Uint8List?> Function() loadBestBytesForSave;

  /// Entrance progress, 0..1, so the chrome fades in once the hero flight
  /// settles instead of flickering as the image passes over it.
  final double progress;

  /// Whether an upward fling from the bottom strip opens the comments. Disabled
  /// while the image is zoomed so panning doesn't get mistaken for the gesture.
  final bool flingToCommentsEnabled;

  final void Function(int delta)? onCommentCountChanged;

  /// Called after the current image is successfully deleted, so the gallery can
  /// drop it from its list and caches.
  final void Function(String imageId)? onImageDeleted;

  const ViewerOverlay({
    super.key,
    required this.imageId,
    required this.groupId,
    required this.imageData,
    required this.uploader,
    required this.commentCount,
    required this.loadBestBytesForSave,
    required this.progress,
    this.uploadedAt,
    this.flingToCommentsEnabled = true,
    this.onCommentCountChanged,
    this.onImageDeleted,
  });

  @override
  State<ViewerOverlay> createState() => _ViewerOverlayState();
}

class _ViewerOverlayState extends State<ViewerOverlay> {
  late int _commentCount;

  // Anchors the frosted overflow dropdown beneath the menu button.
  final GlobalKey _menuButtonKey = GlobalKey();

  // Drives the reactions bar so it can be refreshed after the comments sheet
  // closes, keeping the tally correct.
  final GlobalKey<ReactionsBarState> _reactionsBarKey =
      GlobalKey<ReactionsBarState>();

  // Groups this image was posted in
  List<Group> _postedInGroups = [];

  String get _description => widget.imageData.description ?? '';

  @override
  void initState() {
    super.initState();
    _commentCount = widget.commentCount;
    _initPostedInGroups();
  }

  @override
  void didUpdateWidget(covariant ViewerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The gallery reuses this widget across swipes; reload per-image state when
    // the underlying image changes.
    if (oldWidget.imageId != widget.imageId) {
      _commentCount = widget.commentCount;
      _initPostedInGroups();
    }
  }

  /// Populate the "posted in" pill. If the groups are already cached,
  /// show them synchronously so the pill doesn't flash;
  /// otherwise fetch and fill them in when ready.
  void _initPostedInGroups() {
    final cached = _postedInGroupsCache[widget.imageId];
    if (cached != null) {
      _postedInGroups = _displayGroups(cached);
    } else {
      _postedInGroups = [];
      _loadPostedInGroups();
    }
  }

  Future<void> _loadPostedInGroups() async {
    final imageId = widget.imageId;
    final groups = await fetchPostedInGroups(imageId);
    if (!mounted || imageId != widget.imageId || groups == null) return;
    setState(() => _postedInGroups = _displayGroups(groups));
  }

  /// Apply per-view filtering and ordering to the cached raw group list: hide
  /// the pill unless the image spans multiple groups, and surface the
  /// currently-viewed group first so it leads the pill and can be highlighted.
  List<Group> _displayGroups(List<Group> all) {
    if (all.length < 2 && widget.groupId != null) return const [];
    final groups = List<Group>.from(all);
    if (widget.groupId != null) {
      final idx = groups.indexWhere((g) => g.id == widget.groupId);
      if (idx > 0) groups.insert(0, groups.removeAt(idx));
    }
    return groups;
  }

  Widget _frostedSurface({
    required BorderRadius borderRadius,
    required Color tint,
    required Widget child,
    double sigma = 8,
    double progress = 1,
  }) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: ClipRect(
        child: BackdropFilter.grouped(
          // Shares a single backdrop sampling pass with the other frosted
          // chrome via the enclosing BackdropGroup. Skipped entirely while the
          // chrome is still hidden during the entrance.
          enabled: progress > 0,
          filter: ImageFilter.blur(
              sigmaX: sigma * progress, sigmaY: sigma * progress),
          child: Container(
            decoration: BoxDecoration(
              color: tint.withValues(alpha: tint.a * progress),
              borderRadius: borderRadius,
            ),
            child: Opacity(opacity: progress, child: child),
          ),
        ),
      ),
    );
  }

  /// A circular frosted icon button, as used by the viewer's top action bar.
  Widget _circleAction({
    required IconData icon,
    required VoidCallback onTap,
    required double progress,
  }) {
    return ClipOval(
      child: RepaintBoundary(
        child: InkWell(
          borderRadius: BorderRadius.circular(32),
          onTap: onTap,
          child: _frostedSurface(
            borderRadius: BorderRadius.circular(999),
            tint: Colors.black.withValues(alpha: 0.35),
            progress: progress,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, color: Colors.white, size: 30),
            ),
          ),
        ),
      ),
    );
  }

  /// Overlapping cluster of avatars for the groups the image was posted in
  /// Caps the number of avatars so the pill can't overflow.
  // How far the current-group highlight ring extends beyond an avatar's radius.
  static const double _pillHighlightExtra = 1.5;

  Widget _postedInBadge({double progress = 1}) {
    const double radius = 13;
    const double step = 20;
    const int maxVisible = 4;

    final count = _postedInGroups.length;
    final bool hasOverflow = count > maxVisible;
    final int avatarCount = hasOverflow ? maxVisible : count;
    final int circleCount = hasOverflow ? maxVisible + 1 : count;
    final double clusterWidth = step * (circleCount - 1) + radius * 2;

    // The current group is sorted first and ringed
    final int highlightIndex = widget.groupId == null
        ? -1
        : _postedInGroups.indexWhere((g) => g.id == widget.groupId);

    return _frostedSurface(
      borderRadius: BorderRadius.circular(999),
      tint: Colors.black.withValues(alpha: 0.35),
      sigma: 10,
      progress: progress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Symbols.group_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            SizedBox(
              width: clusterWidth,
              height: radius * 2,
              child: Stack(
                // The highlight ring extends past the cluster bounds
                clipBehavior: Clip.none,
                children: [
                  // Non-highlighted avatars first
                  for (int i = 0; i < avatarCount; i++)
                    if (i != highlightIndex)
                      Positioned(
                        left: i * step,
                        child: _pillAvatar(i, radius, highlighted: false),
                      ),
                  if (hasOverflow)
                    Positioned(
                      left: avatarCount * step,
                      child: CircleAvatar(
                        radius: radius,
                        backgroundColor: Colors.white.withValues(alpha: 0.25),
                        child: Text(
                          "+${count - avatarCount}",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  // Then the highlighted current group on top
                  if (highlightIndex >= 0 && highlightIndex < avatarCount)
                    Positioned(
                      left: highlightIndex * step - _pillHighlightExtra,
                      top: -_pillHighlightExtra,
                      child: _pillAvatar(highlightIndex, radius,
                          highlighted: true),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A group avatar for the pill cluster
  Widget _pillAvatar(int i, double radius, {required bool highlighted}) {
    final avatar = GroupAvatar(_postedInGroups[i], radius: radius);
    if (!highlighted) return avatar;
    return Container(
      width: (radius + _pillHighlightExtra) * 2,
      height: (radius + _pillHighlightExtra) * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: GlobalThemeData.darkColorScheme.primary,
          width: 1.5,
        ),
      ),
      child: avatar,
    );
  }

  /// Present a frosted dialog with a scale entrance instead of the default fade
  Future<void> _showFrostedDialog(WidgetBuilder builder) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, __) => builder(context),
      transitionBuilder: (context, animation, _, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
          child: child,
        );
      },
    );
  }

  /// Frosted dialog listing the groups the image was posted in
  void _showPostedInDialog() {
    _showFrostedDialog(
      (context) {
        return Dialog(
          backgroundColor: Colors.black.withValues(alpha: 0.3),
          insetPadding: const EdgeInsets.all(20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Symbols.group_rounded,
                            color: Colors.white, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            context.l10n.posted_in,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Symbols.close_rounded,
                              color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: _postedInGroups.length,
                        itemBuilder: (context, index) =>
                            _postedInGroupTile(_postedInGroups[index]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _postedInGroupTile(Group group) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: GroupAvatar(group, radius: 20),
      title: Text(
        group.name,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: FutureBuilder<SupabaseResponse<int>>(
        future: getGroupMemberCount(group.id),
        builder: (context, snapshot) {
          final count = snapshot.data?.data;
          final text = count == null
              ? " "
              : "$count ${count == 1 ? context.l10n.member_singular : context.l10n.members_plural}";
          return Text(
            text,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
          );
        },
      ),
      trailing: Icon(Symbols.chevron_right_rounded,
          color: Colors.white.withValues(alpha: 0.7)),
      onTap: () {
        Navigator.pop(context);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ImageFeedPage(group: group)),
        );
      },
    );
  }

  Future<void> _openComments() async {
    final screenHeight = MediaQuery.sizeOf(context).height;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      constraints: BoxConstraints(maxHeight: screenHeight * 0.85),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => CommentsBottomSheet(
        uploaderId: widget.imageData.uploadedBy,
        imageId: widget.imageId,
        primaryGroupId: widget.groupId,
        onCommentCountChanged: (delta) {
          setState(() => _commentCount += delta);
          widget.onCommentCountChanged?.call(delta);
        },
      ),
    );
    // Reactions may have changed while the sheet was open; refresh the bar so
    // its tally and overflow chip stay correct.
    _reactionsBarKey.currentState?.reload();
  }

  void _showFullDescriptionDialog() {
    final locale = Localizations.localeOf(context).toLanguageTag();
    String fmt(DateTime d) =>
        DateFormat.yMMMMd(locale).add_jm().format(d.toLocal());

    final original = DateTime.tryParse(widget.imageData.createdAt);
    final shared = widget.uploadedAt;
    final uploadedLabel = original != null ? fmt(original) : null;
    // Only a reshare to the viewed group earns a second line; a normal
    // post has its group share time equal to the upload time.
    final sharedLabel = (widget.groupId != null &&
            shared != null &&
            original != null &&
            shared.difference(original).abs() > const Duration(minutes: 1))
        ? fmt(shared)
        : null;
    _showFrostedDialog(
      (context) {
        return Dialog(
          backgroundColor: Colors.black.withValues(alpha: 0.3),
          insetPadding: const EdgeInsets.all(20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Metadata
                        UserAvatar(widget.uploader, radius: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.uploader.username,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (uploadedLabel != null)
                                Text(
                                  context.l10n.uploaded_on(uploadedLabel),
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.6),
                                    fontSize: 12,
                                  ),
                                ),
                              if (sharedLabel != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    context.l10n.shared_here_on(sharedLabel),
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.6),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Symbols.close_rounded,
                              color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Description text
                    _description.isEmpty
                        ? Text(
                            context.l10n.no_description,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 15,
                              fontStyle: FontStyle.italic,
                              height: 1.3,
                            ),
                          )
                        : Text(
                            _description,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              height: 1.3,
                            ),
                          ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The viewer's overflow menu: a frosted dropdown anchored under the menu
  /// button. Save is offered to everyone; the rest are owner-only.
  Future<void> _showActionsMenu() async {
    final button =
        _menuButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (button == null || overlayBox == null) return;

    // Bottom-right corner of the button, in overlay coordinates.
    final anchor = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlayBox,
    );

    final action = await showGeneralDialog<_ViewerAction>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (dialogContext, animation, _, __) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return Stack(
          children: [
            Positioned(
              top: anchor.dy + 8,
              right: overlayBox.size.width - anchor.dx,
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
                  alignment: Alignment.topRight,
                  child: _buildActionsMenu(dialogContext),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (action == null || !mounted) return;
    switch (action) {
      case _ViewerAction.save:
        _saveImage();
      case _ViewerAction.addToGroups:
        _addToGroups();
      case _ViewerAction.delete:
        _deleteImage();
    }
  }

  /// The panel listing the available actions.
  Widget _buildActionsMenu(BuildContext menuContext) {
    final divider = Container(
      height: 1,
      color: Colors.white.withValues(alpha: 0.08),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Material(
          color: Colors.black.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
          ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _menuItem(
                  menuContext,
                  icon: Symbols.download_rounded,
                  label: context.l10n.save_to_device,
                  value: _ViewerAction.save,
                ),
                if (_isOwner) ...[
                  divider,
                  _menuItem(
                    menuContext,
                    icon: Symbols.group_add_rounded,
                    label: context.l10n.add_to_group,
                    value: _ViewerAction.addToGroups,
                  ),
                  divider,
                  _menuItem(
                    menuContext,
                    icon: Symbols.delete_rounded,
                    label: context.l10n.delete,
                    value: _ViewerAction.delete,
                    destructive: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuItem(
    BuildContext menuContext, {
    required IconData icon,
    required String label,
    required _ViewerAction value,
    bool destructive = false,
  }) {
    final color = destructive ? const Color(0xFFFF6B6B) : Colors.white;
    return InkWell(
      onTap: () => Navigator.of(menuContext).pop(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Share this already-uploaded photo to more of the user's groups.
  Future<void> _addToGroups() async {
    final userGroups = await getUserGroups();
    if (!mounted) return;
    if (!userGroups.success || userGroups.data == null) {
      showSnackBar(
        context.l10n.error_adding_to_groups(context.errorOr(userGroups.error)),
        color: Colors.red,
      );
      return;
    }

    // Offer only groups the photo isn't already in.
    final current = await fetchPostedInGroups(widget.imageId) ?? const [];
    if (!mounted) return;
    final currentIds = current.map((g) => g.id).toSet();
    final eligible =
        userGroups.data!.where((g) => !currentIds.contains(g.id)).toList();
    if (eligible.isEmpty) {
      showSnackBar(context.l10n.already_in_all_groups);
      return;
    }

    final selected = await showAddToGroupsDialog(context, groups: eligible);
    if (selected == null || selected.isEmpty || !mounted) return;

    final res = await addImageToGroups(widget.imageId, selected.toList());
    if (!mounted) return;
    if (!res.success) {
      showSnackBar(
        context.l10n.error_adding_to_groups(context.errorOr(res.error)),
        color: Colors.red,
      );
      return;
    }

    // Reflect the new groups in the "posted in" pill.
    invalidatePostedInGroups(widget.imageId);
    await _loadPostedInGroups();
    if (!mounted) return;
    showSnackBar(context.l10n.photo_added_success, color: Colors.green);
  }

  Future<void> _saveImage() async {
    final savedMessage = context.l10n.image_saved;
    final errorMessage = context.l10n.error_saving_image;
    final bytes = await widget.loadBestBytesForSave();
    if (!mounted || bytes == null) {
      showSnackBar(errorMessage, color: Colors.red);
      return;
    }
    final success = await downloadImage(
      bytes,
      widget.imageData.uploadedBy,
      widget.imageData.createdAt,
    );
    showSnackBar(
      success ? savedMessage : errorMessage,
      color: success ? Colors.green : Colors.red,
    );
  }

  bool get _isOwner =>
      widget.imageData.uploadedBy == AppAuth.instance.currentUserId;

  Future<void> _deleteImage() async {
    final groups = await fetchPostedInGroups(widget.imageId) ?? const [];
    if (!mounted) return;

    if (groups.length <= 1) {
      // Shared to a single group: removing it there deletes it outright
      final confirmed = await showConfirmDialog(
        context,
        title: context.l10n.delete_photo,
        message: context.l10n.delete_photo_confirm,
        confirmLabel: context.l10n.delete,
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      final res = await deleteImage(widget.imageId);
      _afterDelete(res.success, res.error,
          fullyDeleted: true, removedCurrent: true);
      return;
    }

    final selected = await showDeleteImageDialog(
      context,
      groups: groups,
      currentGroupId: widget.groupId,
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    final res = await removeImageFromGroups(widget.imageId, selected.toList());
    _afterDelete(
      res.success,
      res.error,
      fullyDeleted: res.data ?? false,
      removedCurrent:
          widget.groupId != null && selected.contains(widget.groupId),
    );
  }

  /// Reconcile UI after a delete/removal.
  void _afterDelete(bool success, String? error,
      {required bool fullyDeleted, required bool removedCurrent}) {
    if (!mounted) return;
    if (!success) {
      showSnackBar(error ?? context.l10n.failed_to_delete_photo,
          color: Colors.red);
      return;
    }
    // Refresh the cached pill data
    invalidatePostedInGroups(widget.imageId);

    final message =
        fullyDeleted ? context.l10n.photo_deleted : context.l10n.photo_removed;
    if (fullyDeleted || removedCurrent) {
      // Close the viewer
      Navigator.pop(context);
      widget.onImageDeleted?.call(widget.imageId);
    } else {
      // Still belongs here: stay open and refresh the posted-in pill.
      _loadPostedInGroups();
    }
    showSnackBar(message, color: Colors.green);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.progress;
    // Groups every frosted pill so they share one backdrop blur pass per frame
    // instead of each sampling the photo behind them independently.
    return BackdropGroup(
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: MediaQuery.sizeOf(context).height * 0.2,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragEnd: (details) {
                if (widget.flingToCommentsEnabled &&
                    details.velocity.pixelsPerSecond.dy < -600) {
                  _openComments();
                }
              },
            ),
          ),

          // Top Buttons
          Positioned(
            top: 60,
            left: 16,
            child: _circleAction(
              icon: Symbols.close_rounded,
              onTap: () => Navigator.pop(context),
              progress: t,
            ),
          ),

          Positioned(
            top: 60,
            right: 16,
            child: KeyedSubtree(
              key: _menuButtonKey,
              child: _circleAction(
                icon: CupertinoIcons.ellipsis_vertical,
                onTap: _showActionsMenu,
                progress: t,
              ),
            ),
          ),

          // Posted-in group avatars
          if (_postedInGroups.isNotEmpty)
            Positioned(
              top: 64,
              left: 72,
              right: 72,
              child: Center(
                child: GestureDetector(
                  onTap: _showPostedInDialog,
                  child: _postedInBadge(progress: t),
                ),
              ),
            ),

          // Bottom strip
          Positioned(
            bottom: 15,
            left: 10,
            right: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Emoji reactions
                if (t > 0)
                  Opacity(
                    opacity: t,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 18, left: 2),
                      child: ReactionsBar(
                        key: _reactionsBarKey,
                        imageId: widget.imageId,
                      ),
                    ),
                  ),
                Row(
                  children: [
                    // Image description pill
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: _showFullDescriptionDialog,
                        // Background
                        child: SizedBox(
                          height: 48,
                          child: RepaintBoundary(
                            child: _frostedSurface(
                              borderRadius: BorderRadius.circular(14),
                              tint: Colors.black.withValues(alpha: 0.35),
                              sigma: 10,
                              progress: t,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                child: Row(
                                  children: [
                                    UserAvatar(widget.uploader, radius: 19),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _description.isEmpty
                                          ? Text(
                                              context.l10n.no_description,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white
                                                    .withValues(alpha: 0.5),
                                                fontSize: 14,
                                                fontStyle: FontStyle.italic,
                                              ),
                                            )
                                          : Text(
                                              _description,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Comments button
                    SoftButton(
                      onPressed: _openComments,
                      label: _commentCount.toString(),
                      icon: Symbols.comment_rounded,
                      color: GlobalThemeData.darkColorScheme.primary,
                      opacity: 0.3,
                      height: 48,
                      minLabelWidth: 10,
                      blurBackground: true,
                      progress: t,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
