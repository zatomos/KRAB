import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/models/group.dart';
import 'package:krab/pages/group_images_page.dart';
import 'package:krab/pages/viewer/photo_zoom_controller.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/services/file_saver.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/widgets/comments_bottom_sheet.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/themes/global_theme_data.dart';

class ImageViewer extends StatefulWidget {
  final krab_user.User uploader;
  final String imageId;

  /// The group the image was opened from, or null in the cross-group
  /// "recent photos" gallery where comments span every shared group
  final String? groupId;
  final ImageData lowResImageData;
  final int commentCount;
  final Future<Uint8List?> Function() loadFullImage;
  final Future<Uint8List?>? preloadedFullImage;
  final ValueNotifier<bool>? zoomNotifier;
  final void Function(int delta)? onCommentCountChanged;

  const ImageViewer({
    super.key,
    required this.uploader,
    required this.imageId,
    required this.groupId,
    required this.lowResImageData,
    required this.commentCount,
    required this.loadFullImage,
    this.preloadedFullImage,
    this.zoomNotifier,
    this.onCommentCountChanged,
  });

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer>
    with TickerProviderStateMixin {
  Uint8List get _lowBytes => widget.lowResImageData.imageBytes;
  Uint8List? _fullBytes;
  Uint8List get _bestBytes => _fullBytes ?? _lowBytes;
  Timer? _heroFlightTimer;

  late final AnimationController _controlsAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  late final PhotoZoomController _zoom;
  Size _screenSize = const Size(1, 1);

  late int _commentCount;
  // Whether the current gesture began in the bottom strip, so an upward fling
  // there opens the comments
  bool _dragStartInBottomZone = false;

  // Groups this image was posted in
  List<Group> _postedInGroups = [];

  String get _description => widget.lowResImageData.description ?? '';

  @override
  void initState() {
    super.initState();
    _commentCount = widget.commentCount;

    _zoom = PhotoZoomController(
      vsync: this,
      onZoomChanged: (zoomed) => widget.zoomNotifier?.value = zoomed,
      onNaturalSizeResolved: () {
        if (mounted) setState(() {});
      },
    );

    _zoom.loadNaturalSize(MemoryImage(widget.lowResImageData.imageBytes));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _heroFlightTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _controlsAnim.forward();
      });
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (mounted) _loadFullRes();
      });
    });

    _loadPostedInGroups();
  }

  /// Resolve the groups this image was shared to so they can be shown as
  /// avatars on the image. Only kept when the image spans multiple groups.
  Future<void> _loadPostedInGroups() async {
    final response = await getImageGroups(widget.imageId);
    if (!mounted || !response.success || response.data == null) return;
    final raw = response.data!;
    if (raw.isEmpty) return;

    // Only show the groups pill when the image spans multiple groups.
    // In the cross-group recent photos view (no group context) always show it.
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

    if (!mounted) return;
    setState(() => _postedInGroups = groups);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenSize = MediaQuery.of(context).size;
    _zoom.screenSize = _screenSize;
    if (_zoom.scale <= 1.0) {
      _zoom.applyClampNow();
    }
  }

  @override
  void dispose() {
    _heroFlightTimer?.cancel();
    _controlsAnim.dispose();
    _zoom.dispose();
    widget.zoomNotifier?.value = false;
    super.dispose();
  }

  void _onInteractionStart(ScaleStartDetails details) {
    _zoom.onInteractionStart();
    _dragStartInBottomZone =
        details.localFocalPoint.dy > _screenSize.height * 0.8;
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    _zoom.applyClampDuringInteraction();
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    _zoom.onInteractionEnd();
    // An upward fling from the bottom strip (while not zoomed) opens comments.
    if (_zoom.scale <= 1.05 &&
        _dragStartInBottomZone &&
        details.velocity.pixelsPerSecond.dy < -600) {
      _openComments();
    }
  }

  Future<void> _loadFullRes() async {
    final full = await (widget.preloadedFullImage ?? widget.loadFullImage());
    if (!mounted) return;

    if (full != null) {
      await precacheImage(MemoryImage(full), context);
      if (!mounted) return;
      setState(() {
        _fullBytes = full;
      });
    }
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
        child: BackdropFilter(
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
          MaterialPageRoute(builder: (_) => GroupImagesPage(group: group)),
        );
      },
    );
  }

  void _openComments() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      constraints: BoxConstraints(maxHeight: _screenSize.height * 0.85),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => CommentsBottomSheet(
        uploaderId: widget.lowResImageData.uploadedBy,
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
          DateTime.parse(widget.lowResImageData.createdAt).toLocal(),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Main Image
          Positioned.fill(
            child: RepaintBoundary(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTapDown: (d) => _zoom.doubleTapDetails = d,
                onDoubleTap: _zoom.handleDoubleTap,
                child: InteractiveViewer(
                  transformationController: _zoom.transformationController,
                  minScale: 1.0,
                  maxScale: 10,
                  clipBehavior: Clip.none,
                  onInteractionStart: _onInteractionStart,
                  onInteractionUpdate: _onInteractionUpdate,
                  onInteractionEnd: _onInteractionEnd,
                  child: Hero(
                    tag: "image_${widget.imageId}",
                    child: SizedBox(
                      width: _screenSize.width,
                      height: _screenSize.height,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Low-res base, always visible
                          Image.memory(
                            _lowBytes,
                            fit: BoxFit.contain,
                            width: _screenSize.width,
                            height: _screenSize.height,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.medium,
                          ),
                          // Full-res fades in on top of the low-res base
                          if (_fullBytes != null)
                            TweenAnimationBuilder<double>(
                              key: ValueKey<int>(_fullBytes.hashCode),
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOut,
                              tween: Tween<double>(begin: 0, end: 1),
                              builder: (context, value, child) =>
                                  Opacity(opacity: value, child: child),
                              child: Image.memory(
                                _fullBytes!,
                                fit: BoxFit.contain,
                                width: _screenSize.width,
                                height: _screenSize.height,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
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

          // Overlay controls animate in once the hero flight settles, so they
          // don't flicker as the flying image passes over and behind them
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _controlsAnim,
              builder: (context, _) {
                final t = Curves.easeOut.transform(_controlsAnim.value);
                return IgnorePointer(
                  ignoring: t == 0,
                  child: Stack(
                    children: [
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
                              onTap: () async {
                                final success = await downloadImage(
                                  _bestBytes,
                                  widget.lowResImageData.uploadedBy,
                                  widget.lowResImageData.createdAt,
                                );
                                showSnackBar(
                                  success
                                      ? "Image saved!"
                                      : "Failed to save image",
                                  color: success ? Colors.green : Colors.red,
                                );
                              },
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

                      // Image description
                      Positioned(
                        bottom: 15,
                        left: 10,
                        right: 90,
                        // Pill
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

                      // Comments button
                      Positioned(
                        bottom: 15,
                        right: 10,
                        child: SoftButton(
                          onPressed: _openComments,
                          label: _commentCount.toString(),
                          icon: Symbols.comment_rounded,
                          color: GlobalThemeData.darkColorScheme.primary,
                          opacity: 0.3,
                          height: 48,
                          blurBackground: true,
                          progress: t,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
