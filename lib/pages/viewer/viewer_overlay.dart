import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
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
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/themes/global_theme_data.dart';

/// The non-zoomable chrome layered over the current photo in the gallery.
class ViewerOverlay extends StatefulWidget {
  final String imageId;

  /// The group the image was opened from, or null in the cross-group
  /// "recent photos" gallery where comments span every shared group
  final String? groupId;
  final ImageData imageData;
  final krab_user.User uploader;
  final int commentCount;

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

  const ViewerOverlay({
    super.key,
    required this.imageId,
    required this.groupId,
    required this.imageData,
    required this.uploader,
    required this.commentCount,
    required this.loadBestBytesForSave,
    required this.progress,
    this.flingToCommentsEnabled = true,
    this.onCommentCountChanged,
  });

  @override
  State<ViewerOverlay> createState() => _ViewerOverlayState();
}

class _ViewerOverlayState extends State<ViewerOverlay> {
  late int _commentCount;

  // Groups this image was posted in
  List<Group> _postedInGroups = [];

  String get _description => widget.imageData.description ?? '';

  @override
  void initState() {
    super.initState();
    _commentCount = widget.commentCount;
    _loadPostedInGroups();
  }

  @override
  void didUpdateWidget(covariant ViewerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The gallery reuses this widget across swipes; reload per-image state when
    // the underlying image changes.
    if (oldWidget.imageId != widget.imageId) {
      _commentCount = widget.commentCount;
      _postedInGroups = [];
      _loadPostedInGroups();
    }
  }

  /// Resolve the groups this image was shared to so they can be shown as
  /// avatars on the image. Only kept when the image spans multiple groups.
  Future<void> _loadPostedInGroups() async {
    final imageId = widget.imageId;
    final response = await getImageGroups(imageId);
    if (!mounted || imageId != widget.imageId) return;
    if (!response.success || response.data == null) return;
    final raw = response.data!;
    if (raw.isEmpty) return;

    // Only show the groups pill when the image spans multiple groups.
    // In the cross-group recent photos view, always show it.
    if (raw.length < 2 && widget.groupId != null) return;

    final groups = await Future.wait(raw.map((e) async {
      final map = e as Map<String, dynamic>;
      final id = map['group_id']?.toString() ?? '';
      final iconUrl = await resolveGroupIconUrl(id);
      return Group(
        id: id,
        name: map['group_name']?.toString() ?? '',
        iconUrl: iconUrl,
        createdAt: '',
      );
    }));

    // In a single-group gallery, surface the group being viewed first so it
    // leads the pill and can be highlighted
    if (widget.groupId != null) {
      final idx = groups.indexWhere((g) => g.id == widget.groupId);
      if (idx > 0) groups.insert(0, groups.removeAt(idx));
    }

    if (!mounted || imageId != widget.imageId) return;
    setState(() => _postedInGroups = groups);
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

  void _openComments() {
    final screenHeight = MediaQuery.sizeOf(context).height;
    showModalBottomSheet<void>(
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
  }

  void _showFullDescriptionDialog() {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final uploadDate = DateFormat.yMMMMd(locale).add_jm().format(
          DateTime.parse(widget.imageData.createdAt).toLocal(),
        );
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
                              Text(
                                uploadDate,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 12,
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

  Future<void> _saveImage() async {
    final bytes = await widget.loadBestBytesForSave();
    if (!mounted || bytes == null) {
      showSnackBar("Failed to save image", color: Colors.red);
      return;
    }
    final success = await downloadImage(
      bytes,
      widget.imageData.uploadedBy,
      widget.imageData.createdAt,
    );
    showSnackBar(
      success ? "Image saved!" : "Failed to save image",
      color: success ? Colors.green : Colors.red,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.progress;
    // Groups every frosted pill so they share one backdrop blur pass per frame
    // instead of each sampling the photo behind them independently.
    return BackdropGroup(
      child: Stack(
        children: [
        // An upward fling from the bottom strip opens the comments. Sits below
        // the buttons in paint order so taps on them still win.
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
          child: ClipOval(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => Navigator.pop(context),
                customBorder: const CircleBorder(),
                child: RepaintBoundary(
                  child: _frostedSurface(
                    borderRadius: BorderRadius.circular(999),
                    tint: Colors.white.withValues(alpha: 0.15),
                    progress: t,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(
                        Symbols.close_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        Positioned(
          top: 60,
          right: 16,
          child: ClipOval(
            child: RepaintBoundary(
              child: InkWell(
                borderRadius: BorderRadius.circular(32),
                onTap: _saveImage,
                child: _frostedSurface(
                  borderRadius: BorderRadius.circular(999),
                  tint: Colors.white.withValues(alpha: 0.15),
                  progress: t,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Symbols.download_rounded,
                        color: Colors.white, size: 30),
                  ),
                ),
              ),
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
          child: Row(
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
                          padding: const EdgeInsets.symmetric(horizontal: 8),
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
        ),
        ],
      ),
    );
  }
}
