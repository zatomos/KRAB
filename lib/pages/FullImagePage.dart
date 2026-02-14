import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/models/ImageData.dart';
import 'package:krab/models/User.dart' as KRABUser;
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/services/file_saver.dart';
import 'package:krab/widgets/CommentsBottomSheet.dart';
import 'package:krab/widgets/SoftButton.dart';
import 'package:krab/widgets/UserAvatar.dart';
import 'package:krab/themes/GlobalThemeData.dart';

class FullImagePage extends StatefulWidget {
  final KRABUser.User uploader;
  final String imageId;
  final String groupId;
  final ImageData lowResImageData;
  final int commentCount;
  final Future<Uint8List?> Function() loadFullImage;

  const FullImagePage({
    super.key,
    required this.uploader,
    required this.imageId,
    required this.groupId,
    required this.lowResImageData,
    required this.commentCount,
    required this.loadFullImage,
  });

  @override
  State<FullImagePage> createState() => _FullImagePageState();
}

class _FullImagePageState extends State<FullImagePage>
    with SingleTickerProviderStateMixin {
  late Uint8List _displayedBytes;
  bool _loadingFull = false;

  final TransformationController _transformationController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;

  late AnimationController _animationController;
  Animation<Matrix4>? _animation;

  @override
  void initState() {
    super.initState();
    _displayedBytes = widget.lowResImageData.imageBytes;
    _loadFullRes();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..addListener(() {
        if (_animation != null) {
          _transformationController.value = _animation!.value;
        }
      });
  }

  @override
  void dispose() {
    _animationController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  Future<void> _loadFullRes() async {
    setState(() => _loadingFull = true);
    final full = await widget.loadFullImage();
    if (!mounted) return;

    if (full != null) {
      setState(() {
        _displayedBytes = full;
        _loadingFull = false;
      });
    } else {
      setState(() => _loadingFull = false);
    }
  }

  void _openComments() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => CommentsBottomSheet(
        uploaderId: widget.lowResImageData.uploadedBy,
        imageId: widget.imageId,
        groupId: widget.groupId,
      ),
    );
  }

  void _handleDoubleTap() {
    if (_doubleTapDetails == null) return;

    final position = _doubleTapDetails!.localPosition;
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final double newScale = currentScale > 1.0 ? 1.0 : 3.0;

    final Matrix4 begin = _transformationController.value;

    final double dx = -position.dx * (newScale - 1);
    final double dy = -position.dy * (newScale - 1);

    final Matrix4 scaleMatrix =
        Matrix4.diagonal3Values(newScale, newScale, 1.0);

    final Matrix4 translationMatrix = Matrix4.translationValues(dx, dy, 0.0);

    final Matrix4 end = translationMatrix.multiplied(scaleMatrix);

    _animation = Matrix4Tween(
      begin: begin,
      end: end,
    ).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutCubic,
      ),
    );

    _animationController
      ..reset()
      ..forward();
  }

  void _showFullDescriptionDialog() {
    final desc = widget.lowResImageData.description ?? "";
    if (desc.isEmpty) return;
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
                        UserAvatar(widget.uploader, radius: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.uploader.username,
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
                        ),
                      ],
                    ),
                    const SizedBox(height: 25),
                    Text(
                      desc,
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
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Blurred Background
          Positioned.fill(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
              child: Transform.scale(
                scale: 1.2,
                child: Image.memory(
                  widget.lowResImageData.imageBytes,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),

          Container(color: Colors.black.withValues(alpha: 0.7)),

          // Main Image
          Positioned.fill(
            child: Center(
              child: Transform.translate(
                offset: const Offset(0, 10),
                child: GestureDetector(
                  onDoubleTapDown: (d) => _doubleTapDetails = d,
                  onDoubleTap: _handleDoubleTap,
                  child: InteractiveViewer(
                    transformationController: _transformationController,
                    minScale: 0.5,
                    maxScale: 10,
                    clipBehavior: Clip.none,
                    child: Hero(
                      tag: "image_${widget.imageId}",
                      child: Stack(
                        children: [
                          Image.memory(
                            widget.lowResImageData.imageBytes,
                            fit: BoxFit.contain,
                          ),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 250),
                            opacity: _loadingFull ? 0 : 1,
                            child: Image.memory(
                              _displayedBytes,
                              fit: BoxFit.contain,
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

          // Top Buttons
          Positioned(
            top: 40,
            left: 16,
            child: ClipOval(
              child: Material(
                color: Colors.transparent, // required for ripple + blur
                child: InkWell(
                  onTap: () => Navigator.pop(context),
                  customBorder: const CircleBorder(),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Symbols.close_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            top: 40,
            right: 16,
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
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
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Symbols.download_rounded,
                        color: Colors.white),
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
            child: (widget.lowResImageData.description == "" ||
                    widget.lowResImageData.description == null)
                ? SizedBox(
                    height: 44,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: UserAvatar(widget.uploader, radius: 20),
                    ),
                  )
                : InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _showFullDescriptionDialog,
                    child: SizedBox(
                      height: 44,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                UserAvatar(widget.uploader, radius: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    widget.lowResImageData.description ?? "",
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
              label: widget.commentCount.toString(),
              icon: Symbols.comment_rounded,
              color: GlobalThemeData.darkColorScheme.primary,
              opacity: 0.3,
              blurBackground: true,
            ),
          ),
        ],
      ),
    );
  }
}
