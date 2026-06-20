import 'dart:io';
import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/group.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';

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
    final response = await sendImageToGroups(
      widget.imageFile,
      _selectedGroups.toList(),
      _description.text,
    );
    if (!mounted) return;
    Navigator.of(context).pop(response);
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
          final errorMsg = snapshot.hasError
              ? snapshot.error.toString()
              : (snapshot.data?.error ?? context.l10n.failed_to_load_groups);
          return Center(child: Text("Error: $errorMsg"));
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
    final screenWidth = MediaQuery.of(context).size.width;
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    final insetV = isLandscape ? 4.0 : 24.0;
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      insetPadding: EdgeInsets.symmetric(
        horizontal: isLandscape ? 16 : 40,
        vertical: insetV,
      ),
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
                ? (cst.maxHeight - spacerH - 88).clamp(0.0, 400.0)
                : (MediaQuery.of(context).size.height * 0.40)
                    .clamp(60.0, 400.0);
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
                ),
              ],
            );
          },
        ),
      ),
      actions: keyboardOpen
          ? null
          : [
              SoftButton(
                onPressed: () => Navigator.of(context).pop(),
                label: context.l10n.cancel,
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
                      : GlobalThemeData.darkColorScheme.primary,
                ),
            ],
    );
  }
}
