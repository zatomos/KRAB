import 'dart:io';
import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/group.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/upload_outbox.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';

/// How a send ended: it went out, it was held for later because the device is
/// offline, or it failed for a reason the user has to see.
enum SendOutcome { sent, queued, failed }

class SendImageResult {
  final SendOutcome outcome;

  /// Set when the photo went out, so the caller can offer to undo it.
  final String? imageId;
  final String? error;

  const SendImageResult.sent(this.imageId)
      : outcome = SendOutcome.sent,
        error = null;
  const SendImageResult.queued()
      : outcome = SendOutcome.queued,
        imageId = null,
        error = null;
  const SendImageResult.failed(this.error)
      : outcome = SendOutcome.failed,
        imageId = null;
}

/// Group picker and description dialog for sending a captured image.
class SendImageDialog extends StatefulWidget {
  final File imageFile;

  const SendImageDialog({super.key, required this.imageFile});

  @override
  State<SendImageDialog> createState() => _SendImageDialogState();
}

class _SendImageDialogState extends State<SendImageDialog> {
  final TextEditingController _description = TextEditingController();
  final Set<String> _selectedGroups = {};
  late final Future<SupabaseResponse<List<Group>>> _groupsFuture;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _groupsFuture = getUserGroups();
    UserPreferences.getFavoriteGroups().then((favorites) {
      if (mounted) setState(() => _selectedGroups.addAll(favorites));
    });
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_selectedGroups.isEmpty || _sending) return;
    setState(() => _sending = true);

    final groups = _selectedGroups.toList();

    // If the send got as far as reserving an id, the outbox must retry under
    // that same one. The bytes may already have reached storage, and only the
    // reply been lost; resuming recognises that, while a fresh id would send the
    // photo a second time.
    String? reserved;

    final response = await sendImageToGroups(
      widget.imageFile,
      groups,
      _description.text,
      onReserved: (imageId) async => reserved = imageId,
    );

    // Couldn't reach the server: hold the photo and send it when we can
    if (!response.success && response.offline) {
      await UploadOutbox.instance.enqueue(
        widget.imageFile,
        groups,
        _description.text,
        reservedImageId: reserved,
      );
      if (!mounted) return;
      Navigator.of(context).pop(const SendImageResult.queued());
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(response.success
        ? SendImageResult.sent(response.data)
        : SendImageResult.failed(response.error));
  }

  Widget _buildGroups() {
    return FutureBuilder(
      future: _groupsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(30),
            child: CircularProgressIndicator(),
          );
        }
        if (snapshot.hasError ||
            !snapshot.hasData ||
            !(snapshot.data?.success ?? false)) {
          debugPrint(
              "Failed to load groups: ${snapshot.error ?? snapshot.data?.error}");
          return Center(child: Text(context.l10n.failed_to_load_groups));
        }
        final groups = snapshot.data!.data ?? [];
        if (groups.isEmpty) {
          return Center(child: Text(context.l10n.join_group_first));
        }
        return ListView.builder(
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final group = groups[index];
            return CheckboxListTile(
              title: Text(group.name),
              value: _selectedGroups.contains(group.id),
              onChanged: (value) => setState(() {
                if (value == true) {
                  _selectedGroups.add(group.id);
                } else {
                  _selectedGroups.remove(group.id);
                }
              }),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    final spacerH = (isLandscape && keyboardOpen) ? 0.0 : 8.0;
    final groupsWidget = _buildGroups();

    final Widget dialogContent;
    if (isLandscape) {
      dialogContent = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(widget.imageFile, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(children: [Flexible(child: groupsWidget)])),
        ],
      );
    } else {
      dialogContent = Column(
        children: [
          if (!keyboardOpen) ...[
            Container(
              width: double.infinity,
              height: 200,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                image: DecorationImage(
                    image: FileImage(widget.imageFile), fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Flexible(child: groupsWidget),
        ],
      );
    }

    return AlertDialog(
      insetPadding: isLandscape
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 4)
          : null,
      title: isLandscape ? null : Text(context.l10n.select_groups),
      contentPadding: (isLandscape && keyboardOpen)
          ? EdgeInsets.zero
          : isLandscape
              ? const EdgeInsets.fromLTRB(16, 16, 16, 0)
              : null,
      actionsPadding:
          isLandscape ? const EdgeInsets.fromLTRB(16, 4, 16, 8) : null,
      content: SizedBox(
        width: screenWidth,
        child: LayoutBuilder(
          builder: (_, cst) {
            // Reserve room for description + spacer + safety margin.
            final gh = cst.maxHeight.isFinite
                ? (cst.maxHeight - spacerH - 88).clamp(0.0, 500.0)
                : (MediaQuery.sizeOf(context).height * 0.5).clamp(60.0, 500.0);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Visibility(
                  visible: !(isLandscape && keyboardOpen),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: gh),
                    child: dialogContent,
                  ),
                ),
                SizedBox(height: spacerH),
                RoundedInputField(
                  hintText: context.l10n.add_description,
                  capitalizeSentences: true,
                  controller: _description,
                  maxLength: 199,
                ),
              ],
            );
          },
        ),
      ),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: keyboardOpen
          ? null
          : [
              SoftButton(
                onPressed: () => Navigator.of(context).pop(),
                label: context.l10n.cancel,
                color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
              ),
              if (_sending)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                SoftButton(
                  onPressed: _selectedGroups.isEmpty ? null : _send,
                  label: context.l10n.send,
                  color: _selectedGroups.isEmpty
                      ? GlobalThemeData.darkColorScheme.onSurfaceVariant
                          .withValues(alpha: 0.4)
                      : GlobalThemeData.darkColorScheme.primary,
                ),
            ],
    );
  }
}
