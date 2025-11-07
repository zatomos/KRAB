import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/widgets/UserAvatar.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/models/Comment.dart';
import 'package:krab/models/User.dart' as KRAB_User;
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';

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
  List<Comment> _comments = [];
  bool _loading = true;
  int? _editingCommentIndex;

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
      final comments = await _fetchCommentsForBottomSheet(
          widget.imageId, widget.groupId);
      setState(() {
        _comments = comments;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<List<Comment>> _fetchCommentsForBottomSheet(
      String imageId, String groupId) async {
    return await getComments(imageId, groupId).then((response) {
      if (response.success && response.data != null) {
        final List<dynamic> commentsData = response.data!;
        return commentsData.map((commentData) {
          return Comment(
            userId: commentData['user_id'],
            text: commentData['text'],
            createdAt: DateTime.parse(commentData['created_at']),
          );
        }).toList();
      } else {
        throw Exception("Error fetching comments");
      }
    });
  }

  /// When no comment exists for the current user, call postComment.
  Future<void> _postComment() async {
    final text = _newCommentController.text;
    if (text.isEmpty) return;
    final response = await postComment(widget.imageId, widget.groupId, text);
    if (response.success) {
      setState(() {
        _comments.add(Comment(
          userId: Supabase.instance.client.auth.currentUser!.id,
          text: text,
          createdAt: DateTime.now(),
        ));
        _editingCommentIndex = null;
      });
      _newCommentController.clear();
      showSnackBar(context, context.l10n.comment_added_success, color: Colors.green);
    } else {
      showSnackBar(context, context.l10n.error_adding_comment(response.error ?? "Unknown error"),
          color: Colors.red);
    }
  }

  /// Update comment using updateComment(groupId, imageId, text).
  Future<void> _updateComment() async {
    final text = _newCommentController.text;
    if (text.isEmpty || _editingCommentIndex == null) return;
    final response = await updateComment(widget.imageId, widget.groupId, text);
    if (response.success) {
      setState(() {
        _comments[_editingCommentIndex!] = Comment(
          userId: _comments[_editingCommentIndex!].userId,
          text: text,
          createdAt: _comments[_editingCommentIndex!].createdAt,
        );
        _editingCommentIndex = null;
      });
      _newCommentController.clear();
      showSnackBar(context, context.l10n.comment_updated_success, color: Colors.green);
    } else {
      print(response.error);
      showSnackBar(context, context.l10n.error_updating_comment(response.error ?? "Unknown error"),
          color: Colors.red);
    }
  }

  /// Delete comment using deleteComment(groupId, imageId).
  Future<void> _deleteComment(int index) async {
    final response = await deleteComment(widget.imageId, widget.groupId);
    if (response.success) {
      setState(() {
        _comments.removeAt(index);
        if (_editingCommentIndex == index) _editingCommentIndex = null;
      });
      showSnackBar(context, context.l10n.comment_deleted_success, color: Colors.green);
    } else {
      showSnackBar(context, context.l10n.error_deleting_comment(response.error ?? "Unknown error"),
          color: Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final alreadyCommented =
    _comments.any((comment) => comment.userId == currentUserId);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        top: 16,
        left: 16,
        right: 16,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          // If in edit mode, clear it when user taps outside.
          if (_editingCommentIndex != null) {
            setState(() {
              _editingCommentIndex = null;
              _newCommentController.clear();
            });
          }
          FocusScope.of(context).unfocus();
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header for comments modal
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(context.l10n.comments,
                      style:
                      const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop()),
                ],
              ),
              // Display comments list
              _loading
                  ? const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()))
                  : _comments.isEmpty
                  ? SizedBox(
                  height: 100,
                  child: Center(child: Text(context.l10n.no_comments)))
                  : SizedBox(
                height: 300,
                child: ListView.builder(
                  itemCount: _comments.length,
                  itemBuilder: (context, index) {
                    final comment = _comments[index];
                    return FutureBuilder<KRAB_User.User>(
                      future: getUserDetails(comment.userId).then((response) {
                        if (response.success &&
                            response.data != null) {
                          return response.data ?? KRAB_User.User(
                              id: comment.userId,
                              username: "");
                        }
                        return KRAB_User.User(
                            id: comment.userId,
                            username: "");
                      }),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const ListTile(
                            leading: CircularProgressIndicator(),
                            title: Text("Loading..."),
                          );
                        }
                        final postUser = snapshot.data;
                        if (comment.userId == currentUserId) {
                          return ListTile(
                            leading: UserAvatar(postUser!, radius: 20),
                            title: Text(postUser.username),
                            subtitle: Text(comment.text),
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'edit') {
                                  setState(() {
                                    _editingCommentIndex = index;
                                    _newCommentController.text =
                                        comment.text;
                                  });
                                } else if (value == 'delete') {
                                  _deleteComment(index);
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text(context.l10n.edit)
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(context.l10n.delete)
                                ),
                              ],
                            ),
                          );
                        } else {
                          return ListTile(
                            leading: UserAvatar(postUser!, radius: 20),
                            title: Text(postUser.username),
                            subtitle: Text(comment.text),
                          );
                        }
                      },
                    );
                  },
                ),
              ),
              if ((currentUserId != widget.uploaderId) &&
                  (_editingCommentIndex != null || !alreadyCommented))
                Row(
                  children: [
                    Expanded(
                      child: RoundedInputField(
                        controller: _newCommentController,
                        capitalizeSentences: true,
                        hintText: _editingCommentIndex != null
                            ? context.l10n.edit_comment
                            : context.l10n.post_comment,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () {
                        if (_editingCommentIndex != null) {
                          _updateComment();
                        } else {
                          _postComment();
                        }
                      },
                      icon: const Icon(Icons.send),
                    ),
                  ],
                )
              else
                const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}