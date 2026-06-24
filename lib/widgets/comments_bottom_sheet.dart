import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/widgets/avatars/user_avatar.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/widgets/avatars/avatar_color.dart';
import 'package:krab/models/comment.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/user.dart' as krab_user;
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/dialogs/dialogs.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/time_formatting.dart';

/// A group's comment thread for a single image
class _GroupCommentSection {
  final Group group;
  final bool isPrimary;
  final List<Comment> rootComments;

  /// Total number of comments in this group
  final int commentCount;

  _GroupCommentSection({
    required this.group,
    required this.isPrimary,
    required this.rootComments,
    required this.commentCount,
  });

  String get groupId => group.id;
  String get groupName => group.name;
}

class CommentsBottomSheet extends StatefulWidget {
  final String imageId;

  /// The group whose gallery the image was opened from. When null, the sheet is
  /// in "all groups" mode: comments from every group the image is shared with
  /// are shown together, grouped by group.
  final String? primaryGroupId;
  final String uploaderId;
  final void Function(int delta)? onCommentCountChanged;
  const CommentsBottomSheet({
    super.key,
    required this.imageId,
    required this.primaryGroupId,
    required this.uploaderId,
    this.onCommentCountChanged,
  });

  @override
  CommentsBottomSheetState createState() => CommentsBottomSheetState();
}

class CommentsBottomSheetState extends State<CommentsBottomSheet> {
  final TextEditingController _newCommentController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  List<_GroupCommentSection> _sections = [];
  bool _loading = true;
  bool _isSending = false;

  // Active composing context
  String? _editingCommentId;
  String? _editingGroupId;
  String? _replyingToCommentId;
  String? _replyingToUsername;
  String? _replyingGroupId;

  /// Group a brand-new top-level comment will be posted to
  String? _composingGroupId;

  /// Groups whose comment threads are currently expanded
  final Set<String> _expandedGroupIds = {};

  final Map<String, Future<krab_user.User>> _userCache = {};

  @override
  void initState() {
    super.initState();
    // In a single-group gallery, the target group is known up front, so the
    // input is ready immediately.
    _composingGroupId = widget.primaryGroupId;
    _fetchComments();
  }

  @override
  void dispose() {
    _newCommentController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  bool get _isAllGroupsMode => widget.primaryGroupId == null;

  /// Whether changes to groupId should be reflected in the visible comment
  /// count badge. In all-groups mode the badge counts every group, otherwise it
  /// only tracks the group the image was opened from.
  bool _affectsCount(String groupId) =>
      _isAllGroupsMode || groupId == widget.primaryGroupId;

  Future<void> _fetchComments() async {
    try {
      final response = await getImageCommentsGrouped(
        widget.imageId,
        primaryGroupId: widget.primaryGroupId,
      );
      if (response.success && response.data != null) {
        final sections = await Future.wait(response.data!.map((raw) async {
          final group = raw as Map<String, dynamic>;
          final groupId = group['group_id']?.toString() ?? '';
          final groupComments =
              ((group['comments'] as List?) ?? []).map((commentData) {
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
          final iconUrl = await resolveGroupIconUrl(groupId);
          return _GroupCommentSection(
            group: Group(
              id: groupId,
              name: group['group_name']?.toString() ?? '',
              iconUrl: iconUrl,
              createdAt: '',
            ),
            isPrimary: group['is_primary'] == true,
            rootComments: buildCommentTree(groupComments),
            commentCount: groupComments.length,
          );
        }).toList());

        setState(() {
          _sections = sections;
          // Keep the chosen group across refreshes; only fall back to the
          // default when it's gone or nothing was chosen.
          final chosen = _composingGroupId;
          _composingGroupId =
              (chosen != null && sections.any((s) => s.groupId == chosen))
                  ? chosen
                  : _defaultComposingGroupId(sections);
          // Primary group is open by default, other groups stay collapsed
          for (final section in sections) {
            if (section.isPrimary || _isAllGroupsMode) {
              _expandedGroupIds.add(section.groupId);
            }
          }
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

  String? _defaultComposingGroupId(List<_GroupCommentSection> sections) {
    if (sections.isEmpty) return null;
    final primary = sections.where((s) => s.isPrimary);
    if (primary.isNotEmpty) return primary.first.groupId;
    // All-groups mode: only one group means there's no ambiguity, so select it.
    // With several groups, don't assume; the user must pick one.
    if (sections.length == 1) return sections.first.groupId;
    return null;
  }

  /// Whether a new top-level comment can currently be submitted. Replies and
  /// edits always have a group; a brand-new comment needs one chosen.
  bool get _canSubmit =>
      _editingCommentId != null ||
      _replyingToCommentId != null ||
      _composingGroupId != null;

  Future<void> _postComment() async {
    final text = _newCommentController.text.trim();
    final targetGroup = _replyingGroupId ?? _composingGroupId;
    if (text.isEmpty || _isSending || targetGroup == null) return;
    setState(() => _isSending = true);

    final response = await postComment(
      widget.imageId,
      targetGroup,
      text,
      parentId: _replyingToCommentId,
    );

    if (response.success) {
      _newCommentController.clear();
      _cancelReply();
      _inputFocusNode.unfocus();
      if (_affectsCount(targetGroup)) widget.onCommentCountChanged?.call(1);
      // Make sure the thread the comment landed in is visible
      _expandedGroupIds.add(targetGroup);
      await _fetchComments();
      if (mounted) {
        setState(() => _isSending = false);
        showSnackBar(context.l10n.comment_added_success, color: Colors.green);
      }
    } else {
      if (mounted) {
        setState(() => _isSending = false);
        showSnackBar(
            context.l10n.error_adding_comment(context.errorOr(response.error)),
            color: Colors.red);
      }
    }
  }

  Future<void> _updateComment(String commentId, String groupId) async {
    final text = _newCommentController.text.trim();
    if (text.isEmpty || _editingCommentId == null || _isSending) return;
    setState(() => _isSending = true);

    final response =
        await updateComment(commentId, widget.imageId, groupId, text);
    if (response.success) {
      _newCommentController.clear();
      _inputFocusNode.unfocus();
      setState(() {
        _editingCommentId = null;
        _editingGroupId = null;
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

  Future<void> _deleteComment(String commentId, String groupId) async {
    final confirmed = await showConfirmDialog(context,
        title: context.l10n.confirm_delete_comment,
        confirmLabel: context.l10n.confirm,
        destructive: true);
    if (!confirmed) return;

    final response = await deleteComment(commentId, widget.imageId, groupId);
    if (!mounted) return;

    if (response.success) {
      if (_editingCommentId == commentId) {
        setState(() {
          _editingCommentId = null;
          _editingGroupId = null;
        });
        _newCommentController.clear();
      }
      if (_affectsCount(groupId)) widget.onCommentCountChanged?.call(-1);
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

  void _startReply(Comment comment, String username, String groupId) {
    setState(() {
      _replyingToCommentId = comment.id;
      _replyingToUsername = username;
      _replyingGroupId = groupId;
      _editingCommentId = null;
      _editingGroupId = null;
    });
    _newCommentController.clear();
    _inputFocusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyingToCommentId = null;
      _replyingToUsername = null;
      _replyingGroupId = null;
    });
  }

  void _startEdit(Comment comment, String groupId) {
    setState(() {
      _editingCommentId = comment.id;
      _editingGroupId = groupId;
      _replyingToCommentId = null;
      _replyingToUsername = null;
      _replyingGroupId = null;
      _newCommentController.text = comment.text;
      // Put the cursor at the end of the existing text
      _newCommentController.selection = TextSelection.collapsed(
        offset: comment.text.length,
      );
    });
    _inputFocusNode.requestFocus();
  }

  void _cancelEdit() {
    setState(() {
      _editingCommentId = null;
      _editingGroupId = null;
    });
    _newCommentController.clear();
    _inputFocusNode.unfocus();
  }

  /// Start composing a brand-new top-level comment in section's group.
  void _composeIn(_GroupCommentSection section) {
    setState(() {
      _composingGroupId = section.groupId;
      _editingCommentId = null;
      _editingGroupId = null;
      _replyingToCommentId = null;
      _replyingToUsername = null;
      _replyingGroupId = null;
      _expandedGroupIds.add(section.groupId);
    });
    _newCommentController.clear();
    _inputFocusNode.requestFocus();
  }

  void _toggleExpanded(String groupId) {
    setState(() {
      if (!_expandedGroupIds.remove(groupId)) {
        _expandedGroupIds.add(groupId);
      }
    });
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
  Widget _commentActions(
      Comment comment, String username, bool isCurrentUser, String groupId) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 18),
      child: Row(
        spacing: 32,
        children: [
          GestureDetector(
            onTap: () => _startReply(comment, username, groupId),
            child: Icon(Symbols.chat_rounded, size: 20, color: muted),
          ),
          if (isCurrentUser) ...[
            GestureDetector(
              onTap: () => _startEdit(comment, groupId),
              child: Icon(Symbols.edit_rounded, size: 20, color: muted),
            ),
            GestureDetector(
              onTap: () => _deleteComment(comment.id, groupId),
              child: Icon(Symbols.delete_rounded,
                  size: 20, color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCommentItem(Comment comment, String groupId, {int depth = 0}) {
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
                          _commentActions(
                              comment, username, isCurrentUser, groupId),
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
        ...comment.replies.map(
            (reply) => _buildCommentItem(reply, groupId, depth: depth + 1)),
      ],
    );
  }

  /// Tappable header for a group's thread
  Widget _sectionHeader(_GroupCommentSection section) {
    final color = colorFromName(section.groupName, context);
    final expanded = _expandedGroupIds.contains(section.groupId);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _toggleExpanded(section.groupId),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            GroupAvatar(section.group, radius: 14),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                section.groupName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: color,
                ),
              ),
            ),
            // Number of comments in this group.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Symbols.comment_rounded, size: 13, color: color),
                  const SizedBox(width: 3),
                  Text(
                    '${section.commentCount}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Comment in this group
            if (_sections.length > 1)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: context.l10n.post_comment,
                onPressed: () => _composeIn(section),
                icon: Icon(Symbols.add_comment_rounded, color: color),
              ),
            const SizedBox(width: 8),
            Icon(
              expanded
                  ? Symbols.expand_less_rounded
                  : Symbols.expand_more_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionBody(_GroupCommentSection section) {
    final color = colorFromName(section.groupName, context);
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: section.rootComments.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                context.l10n.no_comments,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: section.rootComments
                  .map((c) => _buildCommentItem(c, section.groupId))
                  .toList(),
            ),
    );
  }

  List<Widget> _buildCommentSections() {
    final primary = _sections.where((s) => s.isPrimary).toList();
    // In all-groups mode every group is shown. In a single-group gallery only
    // other groups that actually have comments are shown.
    final others = _isAllGroupsMode
        ? _sections.toList()
        : _sections
            .where((s) => !s.isPrimary && s.rootComments.isNotEmpty)
            .toList();
    final widgets = <Widget>[];

    // The current group's comments render plainly
    for (final section in primary) {
      if (section.rootComments.isEmpty) {
        widgets.add(_emptyPlaceholder());
      } else {
        widgets.addAll(section.rootComments
            .map((c) => _buildCommentItem(c, section.groupId)));
      }
    }

    if (others.isNotEmpty) {
      if (primary.isNotEmpty) {
        widgets.add(Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
          child: Row(
            children: [
              Expanded(child: Divider(color: Theme.of(context).dividerColor)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  context.l10n.comments_from_other_groups,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(child: Divider(color: Theme.of(context).dividerColor)),
            ],
          ),
        ));
      }
      for (final section in others) {
        widgets.add(_sectionHeader(section));
        if (_expandedGroupIds.contains(section.groupId)) {
          widgets.add(_sectionBody(section));
        }
      }
    }

    // All-groups mode with no comments anywhere
    if (widgets.isEmpty) widgets.add(_emptyPlaceholder());

    return widgets;
  }

  Widget _emptyPlaceholder() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text(context.l10n.no_comments)),
      );

  /// Whether to show the "commenting in" banner: only when the user has chosen
  /// to comment in a group other than the one currently being viewed.
  bool get _showComposingBanner {
    if (_composingGroupId == null) return false;
    // In all-groups mode the banner clarifies which group a comment lands in,
    // but that's only meaningful when the image spans multiple groups.
    if (_isAllGroupsMode) return _sections.length > 1;
    return _composingGroupId != widget.primaryGroupId;
  }

  void _resetComposingGroup() {
    setState(() => _composingGroupId = _defaultComposingGroupId(_sections));
    _inputFocusNode.unfocus();
  }

  String? _groupNameFor(String? groupId) {
    if (groupId == null) return null;
    for (final section in _sections) {
      if (section.groupId == groupId) return section.groupName;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;
    final isComposingNew =
        _editingCommentId == null && _replyingToCommentId == null;
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
          else if (_sections.isEmpty)
            SizedBox(
              height: 100,
              child: Center(child: Text(context.l10n.no_comments)),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(top: 2),
                children: _buildCommentSections(),
              ),
            ),

          // Composing-in indicator: only when a new top-level comment is
          // targeted at a group other than the one being viewed.
          if (!_loading && isComposingNew && _showComposingBanner)
            _composingBanner(),

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
                      _replyBannerText(),
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
                  enabled: _canSubmit,
                  hintText: _editingCommentId != null
                      ? context.l10n.edit_comment
                      : _replyingToCommentId != null
                          ? context.l10n.write_reply
                          : (_canSubmit || _loading)
                              ? context.l10n.post_comment
                              : context.l10n.select_group_to_comment,
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
                      onPressed: _canSubmit
                          ? () {
                              if (_editingCommentId != null) {
                                _updateComment(
                                    _editingCommentId!, _editingGroupId ?? '');
                              } else {
                                _postComment();
                              }
                            }
                          : null,
                      icon: Icon(
                        Symbols.send_rounded,
                        color: _canSubmit
                            ? Colors.white
                            : Theme.of(context).disabledColor,
                      ),
                    ),
            ],
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Indicator showing which group a new top-level comment will be posted to
  Widget _composingBanner() {
    final name = _groupNameFor(_composingGroupId) ?? '';
    final color = colorFromName(name, context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Symbols.add_comment_rounded, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "${context.l10n.commenting_in} $name",
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 14,
              ),
            ),
          ),
          GestureDetector(
            onTap: _resetComposingGroup,
            child: Icon(Symbols.close_rounded,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _replyBannerText() {
    final base = "${context.l10n.replying_to} $_replyingToUsername";
    // Surface the target group only when comments span multiple groups
    if (_sections.length > 1) {
      final groupName = _groupNameFor(_replyingGroupId);
      if (groupName != null) return "$base • $groupName";
    }
    return base;
  }
}
