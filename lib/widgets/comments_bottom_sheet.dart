import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/widgets/user_avatar.dart';
import 'package:krab/models/comment.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/services/time_formatting.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'soft_button.dart';

class CommentsBottomSheet extends StatefulWidget {
  final String imageId;
  final String groupId;
  final String uploaderId;
  const CommentsBottomSheet({
    super.key,
    required this.imageId,
    required this.groupId,
    required this.uploaderId,
  });

  @override
  CommentsBottomSheetState createState() => CommentsBottomSheetState();
}

class CommentsBottomSheetState extends State<CommentsBottomSheet> {
  final TextEditingController _newCommentController = TextEditingController();
  List<Comment> _rootComments = [];
  bool _loading = true;
  String? _editingCommentId;
  String? _replyingToCommentId;
  String? _replyingToUsername;

  @override
  void initState() {
    super.initState();
    _fetchComments();
  }

  @override
  void dispose() {
    _newCommentController.dispose();
    super.dispose();
  }

  Future<void> _fetchComments() async {
    try {
      final response = await getComments(widget.imageId, widget.groupId);
      if (response.success && response.data != null) {
        final List<Comment> flatComments = response.data!.map((commentData) {
          return Comment(
            id: commentData['id']?.toString() ?? '',
            userId: commentData['user_id']?.toString() ?? '',
            text: commentData['text']?.toString() ?? '',
            createdAt: commentData['created_at'] != null
                ? DateTime.parse(commentData['created_at'])
                : DateTime.now(),
            parentId: commentData['parent_id']?.toString(),
          );
        }).toList();

        // Build tree structure
        final rootComments = buildCommentTree(flatComments);

        setState(() {
          _rootComments = rootComments;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint("Error fetching comments: $e");
      setState(() => _loading = false);
    }
  }

  Future<void> _postComment() async {
    final text = _newCommentController.text.trim();
    if (text.isEmpty) return;

    final response = await postComment(
      widget.imageId,
      widget.groupId,
      text,
      parentId: _replyingToCommentId,
    );

    if (response.success) {
      _newCommentController.clear();
      _cancelReply();
      await _fetchComments(); // Refresh to get the new comment with its ID
      if (mounted) {
        showSnackBar(context.l10n.comment_added_success, color: Colors.green);
      }
    } else {
      if (mounted) {
        showSnackBar(
            context.l10n
                .error_adding_comment(response.error ?? "Unknown error"),
            color: Colors.red);
      }
    }
  }

  Future<void> _updateComment(String commentId) async {
    final text = _newCommentController.text.trim();
    if (text.isEmpty || _editingCommentId == null) return;

    final response =
        await updateComment(commentId, widget.imageId, widget.groupId, text);
    if (response.success) {
      _newCommentController.clear();
      setState(() => _editingCommentId = null);
      await _fetchComments();
      if (mounted) {
        showSnackBar(context.l10n.comment_updated_success, color: Colors.green);
      }
    } else {
      if (mounted) {
        showSnackBar(
            context.l10n
                .error_updating_comment(response.error ?? "Unknown error"),
            color: Colors.red);
      }
    }
  }

  Future<void> _deleteComment(String commentId) async {
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n.confirm_delete_comment),
          actions: [
            SoftButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: dialogContext.l10n.cancel,
              color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            ),
            SoftButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();

                final response = await deleteComment(
                    commentId, widget.imageId, widget.groupId);
                if (!mounted) return;

                if (response.success) {
                  if (_editingCommentId == commentId) {
                    setState(() => _editingCommentId = null);
                    _newCommentController.clear();
                  }
                  await _fetchComments();
                  if (!mounted) return;
                  showSnackBar(
                    context.l10n.comment_deleted_success,
                    color: Colors.green,
                  );
                } else {
                  showSnackBar(
                    context.l10n.error_deleting_comment(
                        response.error ?? "Unknown error"),
                    color: Colors.red,
                  );
                }
              },
              label: dialogContext.l10n.confirm,
              color: GlobalThemeData.darkColorScheme.primary,
            ),
          ],
        );
      },
    );
  }

  void _startReply(Comment comment, String username) {
    setState(() {
      _replyingToCommentId = comment.id;
      _replyingToUsername = username;
      _editingCommentId = null;
    });
    _newCommentController.clear();
  }

  void _cancelReply() {
    setState(() {
      _replyingToCommentId = null;
      _replyingToUsername = null;
    });
  }

  void _startEdit(Comment comment) {
    setState(() {
      _editingCommentId = comment.id;
      _replyingToCommentId = null;
      _replyingToUsername = null;
      _newCommentController.text = comment.text;
    });
  }

  Widget _buildCommentItem(Comment comment, {int depth = 0}) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final isCurrentUser = comment.userId == currentUserId;
    final maxDepth = 3; // Limit visual nesting depth
    final effectiveDepth = depth > maxDepth ? maxDepth : depth;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: effectiveDepth * 24.0),
          child: FutureBuilder<krab_user.User>(
            future: getUserDetails(comment.userId).then((response) {
              if (response.success && response.data != null) {
                return response.data!;
              }
              return krab_user.User(id: comment.userId, username: "Unknown");
            }),
            builder: (context, snapshot) {
              final username = snapshot.data?.username ?? "...";
              final user = snapshot.data ??
                  krab_user.User(id: comment.userId, username: "");

              return Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UserAvatar(user, radius: depth == 0 ? 20 : 16),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header: username + time
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: username,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                TextSpan(
                                  text:
                                      " • ${timeAgoLong(context, comment.createdAt)}",
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          // Comment text
                          Text(comment.text),
                          // Action buttons
                          Padding(
                            padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
                            child: Row(
                              spacing: 4,
                              children: [
                                // Reply button
                                GestureDetector(
                                  onTap: () => _startReply(comment, username),
                                  child: Text(
                                    context.l10n.reply,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (isCurrentUser) ...[
                                  const SizedBox(width: 16),
                                  GestureDetector(
                                    onTap: () => _startEdit(comment),
                                    child: Text(
                                      context.l10n.edit,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  GestureDetector(
                                    onTap: () => _deleteComment(comment.id),
                                    child: Text(
                                      context.l10n.delete,
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).colorScheme.error,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          )
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        // Render replies recursively
        ...comment.replies
            .map((reply) => _buildCommentItem(reply, depth: depth + 1)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          top: 16,
          left: 16,
          right: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(context.l10n.comments,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Symbols.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Comments list
            if (_loading)
              const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_rootComments.isEmpty)
              SizedBox(
                height: 100,
                child: Center(child: Text(context.l10n.no_comments)),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _rootComments.length,
                  itemBuilder: (context, index) =>
                      _buildCommentItem(_rootComments[index]),
                ),
              ),

            const SizedBox(height: 12),

            // Reply indicator
            if (_replyingToCommentId != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Symbols.reply_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "${context.l10n.replying_to} $_replyingToUsername",
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: _cancelReply,
                      child: Icon(Symbols.close_rounded,
                          size: 18,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),

            if (_replyingToCommentId != null) const SizedBox(height: 8),

            // Input row
            Row(
              children: [
                Expanded(
                  child: RoundedInputField(
                    controller: _newCommentController,
                    capitalizeSentences: true,
                    hintText: _editingCommentId != null
                        ? context.l10n.edit_comment
                        : _replyingToCommentId != null
                            ? context.l10n.write_reply
                            : context.l10n.post_comment,
                  ),
                ),
                IconButton(
                  onPressed: () {
                    if (_editingCommentId != null) {
                      _updateComment(_editingCommentId!);
                    } else {
                      _postComment();
                    }
                  },
                  icon: const Icon(Symbols.send_rounded, color: Colors.white),
                ),
              ],
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
