import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/models/image_data.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/pages/viewer/photo_zoom_controller.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/services/file_saver.dart';
import 'package:krab/widgets/comments_bottom_sheet.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/themes/global_theme_data.dart';

class ImageViewer extends StatefulWidget {
  final krab_user.User uploader;
  final String imageId;
  final String groupId;
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
  late Uint8List _displayedBytes;
  bool _heroFlightActive = true;
  Timer? _heroFlightTimer;

  late final PhotoZoomController _zoom;
  Size _screenSize = const Size(1, 1);

  late int _commentCount;
  // Whether the current gesture began in the bottom strip, so an upward fling
  // there opens the comments
  bool _dragStartInBottomZone = false;

  String get _description => widget.lowResImageData.description ?? '';

  @override
  void initState() {
    super.initState();
    _commentCount = widget.commentCount;
    _displayedBytes = widget.lowResImageData.imageBytes;

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
        if (mounted) setState(() => _heroFlightActive = false);
      });
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (mounted) _loadFullRes();
      });
    });
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
        _displayedBytes = full;
      });
    }
  }

  Widget _frostedSurface({
    required BorderRadius borderRadius,
    required Color tint,
    required Widget child,
    double sigma = 8,
  }) {
    final decorated = Container(
      decoration: BoxDecoration(color: tint, borderRadius: borderRadius),
      child: child,
    );
    if (_heroFlightActive) {
      return ClipRRect(borderRadius: borderRadius, child: decorated);
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: decorated,
        ),
      ),
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
        groupId: widget.groupId,
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
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) {
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
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeOut,
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: Image.memory(
                          _displayedBytes,
                          key: ValueKey<int>(_displayedBytes.hashCode),
                          fit: BoxFit.contain,
                          width: _screenSize.width,
                          height: _screenSize.height,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
                      _displayedBytes,
                      widget.lowResImageData.uploadedBy,
                      widget.lowResImageData.createdAt,
                    );
                    showSnackBar(
                      success ? "Image saved!" : "Failed to save image",
                      color: success ? Colors.green : Colors.red,
                    );
                  },
                  child: _frostedSurface(
                    borderRadius: BorderRadius.circular(999),
                    tint: Colors.white.withValues(alpha: 0.15),
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
                height: 44,
                child: RepaintBoundary(
                  child: _frostedSurface(
                    borderRadius: BorderRadius.circular(14),
                    tint: Colors.black.withValues(alpha: 0.35),
                    sigma: 10,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          UserAvatar(widget.uploader, radius: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _description.isEmpty
                                ? Text(
                                    context.l10n.no_description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.5),
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
              blurBackground: !_heroFlightActive,
            ),
          ),
        ],
      ),
    );
  }
}
