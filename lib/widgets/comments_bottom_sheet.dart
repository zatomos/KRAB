import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/models/comment.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/time_formatting.dart';

class CommentsBottomSheet extends StatefulWidget {
  final String imageId;
  final String groupId;
  final String uploaderId;
  final void Function(int delta)? onCommentCountChanged;
  const CommentsBottomSheet({
    super.key,
    required this.imageId,
    required this.groupId,
    required this.uploaderId,
    this.onCommentCountChanged,
  });

  @override
  CommentsBottomSheetState createState() => CommentsBottomSheetState();
}

class CommentsBottomSheetState extends State<CommentsBottomSheet> {
  final TextEditingController _newCommentController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  List<Comment> _rootComments = [];
  bool _loading = true;
  bool _isSending = false;
  String? _editingCommentId;
  String? _replyingToCommentId;
  String? _replyingToUsername;
  final Map<String, Future<krab_user.User>> _userCache = {};

  @override
  void initState() {
    super.initState();
    _fetchComments();
  }

  @override
  void dispose() {
    _newCommentController.dispose();
    _inputFocusNode.dispose();
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
    if (text.isEmpty || _isSending) return;
    setState(() => _isSending = true);

    final response = await postComment(
      widget.imageId,
      widget.groupId,
      text,
      parentId: _replyingToCommentId,
    );

    if (response.success) {
      _newCommentController.clear();
      _cancelReply();
      _inputFocusNode.unfocus();
      widget.onCommentCountChanged?.call(1);
      await _fetchComments();
      if (mounted) {
        setState(() => _isSending = false);
        showSnackBar(context.l10n.comment_added_success, color: Colors.green);
      }
    } else {
      if (mounted) {
        setState(() => _isSending = false);
        showSnackBar(
            context.l10n
                .error_adding_comment(context.errorOr(response.error)),
            color: Colors.red);
      }
    }
  }

  Future<void> _updateComment(String commentId) async {
    final text = _newCommentController.text.trim();
    if (text.isEmpty || _editingCommentId == null || _isSending) return;
    setState(() => _isSending = true);

    final response =
        await updateComment(commentId, widget.imageId, widget.groupId, text);
    if (response.success) {
      _newCommentController.clear();
      _inputFocusNode.unfocus();
      setState(() {
        _editingCommentId = null;
        _isSending = false;
      });
      await _fetchComments();
      if (mounted) {
        showSnackBar(context.l10n.comment_updated_success, color: Colors.green);
      }
    } else {
      if (mounted) {
        setState(() => _isSending = false);
        showSnackBar(
            context.l10n
                .error_updating_comment(context.errorOr(response.error)),
            color: Colors.red);
      }
    }
  }

  Future<void> _deleteComment(String commentId) async {
    final confirmed = await showConfirmDialog(context,
        title: context.l10n.confirm_delete_comment,
        confirmLabel: context.l10n.confirm,
        destructive: true);
    if (!confirmed) return;

    final response =
        await deleteComment(commentId, widget.imageId, widget.groupId);
    if (!mounted) return;

    if (response.success) {
      if (_editingCommentId == commentId) {
        setState(() => _editingCommentId = null);
        _newCommentController.clear();
      }
      widget.onCommentCountChanged?.call(-1);
      await _fetchComments();
      if (!mounted) return;
      showSnackBar(context.l10n.comment_deleted_success, color: Colors.green);
    } else {
      showSnackBar(
        context.l10n.error_deleting_comment(context.errorOr(response.error)),
        color: Colors.red,
      );
    }
  }

  void _startReply(Comment comment, String username) {
    setState(() {
      _replyingToCommentId = comment.id;
      _replyingToUsername = username;
      _editingCommentId = null;
    });
    _newCommentController.clear();
    _inputFocusNode.requestFocus();
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
      // Put the cursor at the end of the existing text
      _newCommentController.selection = TextSelection.collapsed(
        offset: comment.text.length,
      );
    });
    _inputFocusNode.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editingCommentId = null);
    _newCommentController.clear();
    _inputFocusNode.unfocus();
  }

  /// Resolve the author of a comment
  Future<krab_user.User> _userFor(Comment comment) {
    return _userCache.putIfAbsent(
      comment.userId,
      () => getUserDetails(comment.userId).then((response) =>
          (response.success && response.data != null)
              ? response.data!
              : krab_user.User(id: comment.userId, username: "Unknown")),
    );
  }

  /// Reply / edit / delete row under a comment
  Widget _commentActions(Comment comment, String username, bool isCurrentUser) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 18),
      child: Row(
        spacing: 32,
        children: [
          GestureDetector(
            onTap: () => _startReply(comment, username),
            child: Icon(Symbols.chat_rounded, size: 20, color: muted),
          ),
          if (isCurrentUser) ...[
            GestureDetector(
              onTap: () => _startEdit(comment),
              child: Icon(Symbols.edit_rounded, size: 20, color: muted),
            ),
            GestureDetector(
              onTap: () => _deleteComment(comment.id),
              child: Icon(Symbols.delete_rounded,
                  size: 20, color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
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
            future: _userFor(comment),
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
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14),
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
                          _commentActions(comment, username, isCurrentUser),
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
    final bottomInset = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(
        bottom: bottomInset,
        left: 16,
        right: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text(context.l10n.comments,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),

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
                padding: const EdgeInsets.only(top: 6),
                itemCount: _rootComments.length,
                itemBuilder: (context, index) =>
                    _buildCommentItem(_rootComments[index]),
              ),
            ),

          const SizedBox(height: 12),

          // Editing indicator
          if (_editingCommentId != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Symbols.edit_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.l10n.editing_comment,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _cancelEdit,
                    child: Icon(Symbols.close_rounded,
                        size: 24,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],

          // Reply indicator
          if (_replyingToCommentId != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    onTap: () {
                      _cancelReply();
                      _inputFocusNode.unfocus();
                    },
                    child: Icon(Symbols.close_rounded,
                        size: 24,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                  focusNode: _inputFocusNode,
                  capitalizeSentences: true,
                  hintText: _editingCommentId != null
                      ? context.l10n.edit_comment
                      : _replyingToCommentId != null
                          ? context.l10n.write_reply
                          : context.l10n.post_comment,
                ),
              ),
              _isSending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : IconButton(
                      onPressed: () {
                        if (_editingCommentId != null) {
                          _updateComment(_editingCommentId!);
                        } else {
                          _postComment();
                        }
                      },
                      icon:
                          const Icon(Symbols.send_rounded, color: Colors.white),
                    ),
            ],
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
