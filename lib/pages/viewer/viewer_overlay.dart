import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:intl/intl.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/group.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/services/file_saver.dart';
import 'package:krab/pages/viewer/comments_bottom_sheet.dart';
import 'package:krab/pages/viewer/frosted.dart';
import 'package:krab/pages/viewer/posted_in_badge.dart';
import 'package:krab/pages/viewer/viewer_actions_menu.dart';
import 'package:krab/widgets/dialogs/add_to_groups_dialog.dart';
import 'package:krab/widgets/dialogs/delete_image_dialog.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/reactions_bar.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/shared_image_api.dart';

/// The chrome layered over the current image in the gallery.
class ViewerOverlay extends StatefulWidget {
  /// The image, with every copy of it this device can reach. Everything the
  /// overlay reads gathers from all of them; everything it writes goes to one.
  final SharedImage image;

  /// The group the image was opened from, or null in the cross-group
  /// "recent images" gallery where comments span every shared group
  final Group? group;
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

  /// Entrance progress, so the chrome fades in once the hero flight
  /// settles instead of flickering as the image passes over it.
  final double progress;

  /// Whether an upward fling from the bottom strip opens the comments. Disabled
  /// while the image is zoomed so panning doesn't get mistaken for the gesture.
  final bool flingToCommentsEnabled;

  final void Function(int delta)? onCommentCountChanged;
  final void Function(SharedImage image)? onImageDeleted;

  /// Copies of this image that now exist on servers it was not on before.
  final void Function(List<ImageRef> copies)? onCopiesAdded;

  const ViewerOverlay({
    super.key,
    required this.image,
    required this.group,
    required this.imageData,
    required this.uploader,
    required this.commentCount,
    required this.loadBestBytesForSave,
    required this.progress,
    this.uploadedAt,
    this.flingToCommentsEnabled = true,
    this.onCommentCountChanged,
    this.onImageDeleted,
    this.onCopiesAdded,
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
  /// Reads the union of the image's copies and writes to one of them.
  SharedImageApi get _api => SharedImageApi(widget.image);

  String? get _groupId => widget.group?.id;

  final GlobalKey<ReactionsBarState> _reactionsBarKey =
      GlobalKey<ReactionsBarState>();

  // Groups this image was posted in
  List<Group> _postedInGroups = [];

  // Whether the user moderates the group the image was opened from.
  bool _canModerate = false;

  String get _description => widget.imageData.description ?? '';

  @override
  void initState() {
    super.initState();
    _commentCount = widget.commentCount;
    _initPostedInGroups();
    _initModeration();
  }

  /// Group owners and admins may delete anyone's image from their group.
  void _initModeration() {
    final group = widget.group;
    if (group == null) return;
    final instance = InstanceRegistry.instance.byId(group.instanceId);
    if (instance == null) return;
    instance.viewer.canModerateGroup(group.id).then((canModerate) {
      if (mounted && canModerate != _canModerate) {
        setState(() => _canModerate = canModerate);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ViewerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The gallery reuses this widget across swipes; reload per-image state when
    // the underlying image changes.
    if (oldWidget.image.identity != widget.image.identity) {
      _commentCount = widget.commentCount;
      _initPostedInGroups();
    }
  }

  /// Populate the "posted in" pill. If the groups are already cached,
  /// show them synchronously so the pill doesn't flash;
  /// otherwise fetch and fill them in when ready.
  void _initPostedInGroups() {
    final cached = _api.cachedPostedInGroups();
    if (cached != null) {
      _postedInGroups = _displayGroups(cached);
    } else {
      _postedInGroups = [];
      _loadPostedInGroups();
    }
  }

  Future<void> _loadPostedInGroups() async {
    final identity = widget.image.identity;
    final groups = await _api.postedInGroups();
    if (!mounted || identity != widget.image.identity || groups == null) {
      return;
    }
    setState(() => _postedInGroups = _displayGroups(groups));
  }

  /// Apply per-view filtering and ordering to the cached raw group list: hide
  /// the pill unless the image spans multiple groups, and surface the
  /// currently-viewed group first so it leads the pill and can be highlighted.
  List<Group> _displayGroups(List<Group> all) {
    if (all.length < 2 && _groupId != null) return const [];
    final groups = List<Group>.from(all);
    if (_groupId != null) {
      final idx = groups.indexWhere((g) => g.id == _groupId);
      if (idx > 0) groups.insert(0, groups.removeAt(idx));
    }
    return groups;
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
        image: widget.image,
        uploaderId: widget.imageData.uploadedBy,
        primaryGroup: widget.group,
        initialCommentCount: _commentCount,
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
    final sharedLabel = (_groupId != null &&
            shared != null &&
            original != null &&
            shared.difference(original).abs() > const Duration(minutes: 1))
        ? fmt(shared)
        : null;
    showFrostedDialog<void>(
      context,
      padding: const EdgeInsets.all(18),
      content: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
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
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Symbols.close_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _descriptionText(fontSize: 15, height: 1.3),
        ],
      ),
    );
  }

  /// The image's description.
  Widget _descriptionText({
    required double fontSize,
    double? height,
    FontWeight? weight,
    int? maxLines,
  }) {
    final empty = _description.isEmpty;
    return Text(
      empty ? context.l10n.no_description : _description,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: TextStyle(
        color: empty ? Colors.white.withValues(alpha: 0.5) : Colors.white,
        fontSize: fontSize,
        height: height,
        fontStyle: empty ? FontStyle.italic : FontStyle.normal,
        fontWeight: empty ? null : weight,
      ),
    );
  }

  /// Open the overflow menu and carry out whatever it resolves to.
  Future<void> _openActionsMenu() async {
    final action = await showViewerActionsMenu(
      context,
      buttonKey: _menuButtonKey,
      isOwner: _isOwner,
      canModerate: _canModerate,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case ViewerAction.save:
        _saveImage();
      case ViewerAction.addToGroups:
        _addToGroups();
      case ViewerAction.delete:
        _deleteImage();
    }
  }

  /// Share this already-uploaded image to more of the user's groups.
  Future<void> _addToGroups() async {
    final userGroups = await _api.groupsItCouldJoin();
    if (!mounted) return;
    if (userGroups == null) {
      showSnackBar(
        context.l10n.error_adding_to_groups(context.errorText(errorServer)),
        tone: SnackTone.failure,
      );
      return;
    }

    // Offer only groups the image isn't already in, on any server.
    final current = await _api.postedInGroups() ?? const [];
    if (!mounted) return;
    final currentKeys = {for (final g in current) '${g.instanceId}/${g.id}'};
    final eligible = userGroups
        .where((g) => !currentKeys.contains('${g.instanceId}/${g.id}'))
        .toList();
    if (eligible.isEmpty) {
      showSnackBar(context.l10n.already_in_all_groups);
      return;
    }

    final selected = await showAddToGroupsDialog(context, groups: eligible);
    if (selected == null || selected.isEmpty || !mounted) return;

    // A group on a server that has no copy yet needs one, so the image goes up
    // there under the same share id and the two read as one image.
    final res = await _api.addToGroups(
      selected,
      loadBytes: widget.loadBestBytesForSave,
      description: _description,
    );
    if (!mounted) return;

    // Some servers can take their copy while another refuses
    final created = res.data ?? const <ImageRef>[];
    if (created.isNotEmpty) widget.onCopiesAdded?.call(created);

    // Reflect the new groups in the "posted in" pill.
    _api.invalidatePostedInGroups();
    await _loadPostedInGroups();
    if (!mounted) return;

    showSnackBar(
      res.success
          ? context.l10n.photo_added_success
          : context.l10n.error_adding_to_groups(context.errorText(res.error)),
      tone: res.success ? SnackTone.success : SnackTone.failure,
    );
  }

  Future<void> _saveImage() async {
    final savedMessage = context.l10n.image_saved;
    final errorMessage = context.l10n.error_saving_image;
    final bytes = await widget.loadBestBytesForSave();
    if (!mounted) return;
    if (bytes == null) {
      showSnackBar(errorMessage, tone: SnackTone.failure);
      return;
    }
    final success = await downloadImage(
      bytes,
      widget.imageData.uploadedBy,
      widget.imageData.createdAt,
    );
    showSnackBar(
      success ? savedMessage : errorMessage,
      tone: success ? SnackTone.success : SnackTone.failure,
    );
  }

  bool get _isOwner =>
      _api.isOwnedBy(widget.imageData.uploadedBy, widget.uploader.instanceId);

  Future<void> _deleteImage() async {
    // A moderator can only remove someone else's image from the group they
    // moderate, never from the other groups it was shared to.
    if (!_isOwner) {
      final group = widget.group;
      if (group == null) return;
      final confirmed = await showConfirmDialog(
        context,
        title: context.l10n.delete_photo,
        message: context.l10n.delete_photo_group_confirm,
        confirmLabel: context.l10n.delete,
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      final res = await _api.removeFromGroups([group]);
      _afterDelete(res.success, res.error,
          fullyDeleted: res.data ?? false, removedCurrent: true);
      return;
    }

    final groups = await _api.postedInGroups() ?? const [];
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
      final res = await _api.delete();
      _afterDelete(res.success, res.error,
          fullyDeleted: true, removedCurrent: true);
      return;
    }

    final selected = await showDeleteImageDialog(
      context,
      groups: groups,
      currentGroupId: _groupId,
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    final chosen = groups.where((g) => selected.contains(g.id)).toList();
    final res = await _api.removeFromGroups(chosen);
    _afterDelete(
      res.success,
      res.error,
      fullyDeleted: res.data ?? false,
      removedCurrent: _groupId != null && selected.contains(_groupId),
    );
  }

  /// Reconcile UI after a delete/removal.
  void _afterDelete(bool success, String? error,
      {required bool fullyDeleted, required bool removedCurrent}) {
    if (!mounted) return;
    if (!success) {
      showSnackBar(error ?? context.l10n.failed_to_delete_photo,
          tone: SnackTone.failure);
      return;
    }
    // Refresh the cached pill data
    _api.invalidatePostedInGroups();

    final message =
        fullyDeleted ? context.l10n.photo_deleted : context.l10n.photo_removed;
    if (fullyDeleted || removedCurrent) {
      // Close the viewer
      Navigator.pop(context);
      widget.onImageDeleted?.call(widget.image);
    } else {
      // Still belongs here: stay open and refresh the posted-in pill.
      _loadPostedInGroups();
    }
    showSnackBar(message, tone: SnackTone.success);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.progress;
    // Groups every frosted pill so they share one backdrop blur pass per frame
    // instead of each sampling the image behind them independently.
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
            top: 48,
            left: 4,
            child: CircleAction(
              icon: Symbols.close_rounded,
              onTap: () => Navigator.pop(context),
              progress: t,
            ),
          ),

          Positioned(
            top: 48,
            right: 4,
            child: CircleAction(
              visualKey: _menuButtonKey,
              icon: CupertinoIcons.ellipsis_vertical,
              onTap: _openActionsMenu,
              progress: t,
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
                  onTap: () => showPostedInDialog(context, _postedInGroups),
                  child: PostedInBadge(
                    groups: _postedInGroups,
                    currentGroupId: _groupId,
                    progress: t,
                  ),
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
                        image: widget.image,
                        preferInstanceId: widget.group?.instanceId,
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
                            child: FrostedSurface(
                              borderRadius: BorderRadius.circular(14),
                              tint: frostedTint,
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
                                      child: _descriptionText(
                                        fontSize: 14,
                                        weight: FontWeight.w500,
                                        maxLines: 2,
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
                      color: Theme.of(context).colorScheme.primary,
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
