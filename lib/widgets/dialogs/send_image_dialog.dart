import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/models/group.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/share_id.dart';
import 'package:krab/services/upload_outbox.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/avatars/group_avatar.dart';
import 'package:krab/widgets/dialogs/image_preview_dialog.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/services/instance/instances.dart';

/// How a send ended
enum SendOutcome { sent, sentPartially, queued, failed }

class SendImageResult {
  final SendOutcome outcome;

  /// What was sent, so the caller can offer to undo it. Holds every copy when
  /// the image went to more than one instance, so undoing takes them all back.
  final SharedImage? image;
  final String? error;

  /// Labels of the servers that refused their copy, in the order they were
  /// tried.
  final List<String> refusedBy;

  /// Labels of the servers that couldn't be reached.
  final List<String> queuedFor;

  const SendImageResult.sent(this.image, {this.queuedFor = const []})
      : outcome = SendOutcome.sent,
        error = null,
        refusedBy = const [];

  /// Some copies landed and at least one server refused its own.
  const SendImageResult.sentPartially(this.image, this.error, this.refusedBy,
      {this.queuedFor = const []})
      : outcome = SendOutcome.sentPartially;
  const SendImageResult.queued()
      : outcome = SendOutcome.queued,
        image = null,
        error = null,
        refusedBy = const [],
        queuedFor = const [];
  const SendImageResult.failed(this.error)
      : outcome = SendOutcome.failed,
        image = null,
        refusedBy = const [],
        queuedFor = const [];
}

/// One instance's groups, for the picker.
class _InstanceGroups {
  const _InstanceGroups(this.instance, this.groups);
  final KrabInstance instance;
  final List<Group> groups;
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

  /// Selected groups, as `instanceId/groupId`.
  final Set<String> _selected = {};

  late final Future<List<_InstanceGroups>> _groupsFuture;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _groupsFuture = _loadGroups();
    UserPreferences.getFavoriteGroups().then((favorites) {
      if (mounted) setState(() => _selected.addAll(favorites));
    });
  }

  /// Every connected instance's groups, fetched together.
  Future<List<_InstanceGroups>> _loadGroups() async {
    final instances = InstanceRegistry.instance.all;
    final responses = await Future.wait(
        instances.map((i) => i.api.getUserGroups().orGiveUp()));

    final loaded = <_InstanceGroups>[];
    for (var i = 0; i < instances.length; i++) {
      final response = responses[i];
      if (!response.success || response.data == null) {
        debugPrint('Send: groups from ${instances[i].id} unavailable '
            '(${response.error})');
        continue;
      }
      if (response.data!.isEmpty) continue;
      loaded.add(_InstanceGroups(instances[i], response.data!));
    }
    return loaded;
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  /// The selected groups, split by the instance that owns them.
  Map<String, List<String>> _selectionByInstance() {
    final byInstance = <String, List<String>>{};
    for (final key in _selected) {
      final slash = key.indexOf('/');
      if (slash <= 0) continue;
      (byInstance[key.substring(0, slash)] ??= [])
          .add(key.substring(slash + 1));
    }
    return byInstance;
  }

  Future<void> _send() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);

    final byInstance = _selectionByInstance();

    // One id shared by every copy, so the copies can be recognised later as the
    // one image they are.
    final shareId = newShareId();

    // Prepared once and handed to every instance, so the copies are byte
    // identical and the image is only re-encoded once.
    final Uint8List prepared;
    try {
      prepared = await prepareImageForUpload(widget.imageFile);
    } catch (error) {
      debugPrint('Send: could not prepare the image: $error');
      if (!mounted) return;
      Navigator.of(context).pop(const SendImageResult.failed(errorServer));
      return;
    }

    final sent = <ImageRef>[];
    final refusedBy = <String>[];
    final queuedFor = <String>[];
    String? failure;

    for (final entry in byInstance.entries) {
      final instance = InstanceRegistry.instance.byId(entry.key);
      if (instance == null) continue;

      // The outbox has to retry under any id this send reserved, or it would
      // send the image a second time.
      String? reserved;

      String? storedShareId = shareId;

      final response = await instance.api.sendImageToGroups(
        widget.imageFile,
        entry.value,
        _description.text,
        shareId: shareId,
        preparedBytes: prepared,
        onReserved: (imageId) async => reserved = imageId,
        onShareIdDropped: () => storedShareId = null,
      );

      if (response.success && response.data != null) {
        final imageId = response.data!;
        sent.add(ImageRef(
          instanceId: instance.id,
          id: imageId,
          shareId: storedShareId,
        ));
        continue;
      }

      // Couldn't reach this server: hold its copy and send it when we can.
      if (response.offline) {
        await UploadOutbox.instance.enqueue(
          instance.id,
          widget.imageFile,
          entry.value,
          _description.text,
          reservedImageId: reserved,
          shareId: shareId,
        );
        queuedFor.add(instance.label);
        continue;
      }

      debugPrint('Send: ${instance.id} refused the image (${response.error})');
      failure ??= response.error;
      refusedBy.add(instance.label);
    }

    if (!mounted) return;

    if (sent.isNotEmpty) {
      Navigator.of(context).pop(failure == null
          ? SendImageResult.sent(SharedImage(sent), queuedFor: queuedFor)
          : SendImageResult.sentPartially(SharedImage(sent), failure, refusedBy,
              queuedFor: queuedFor));
      return;
    }
    // Nothing landed.
    Navigator.of(context).pop(queuedFor.isNotEmpty
        ? const SendImageResult.queued()
        : SendImageResult.failed(failure ?? errorServer));
  }

  /// Full-screen look at the image.
  void _openPreview() {
    if (_sending) return;
    showImagePreview(context, widget.imageFile);
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
        if (snapshot.hasError || !snapshot.hasData) {
          debugPrint("Failed to load groups: ${snapshot.error}");
          return Center(child: Text(context.l10n.failed_to_load_groups));
        }
        final loaded = snapshot.data!;
        if (loaded.isEmpty) {
          return Center(child: Text(context.l10n.join_group_first));
        }

        final showInstances = loaded.length > 1;
        final rows = <Widget>[];
        for (final entry in loaded) {
          if (showInstances) rows.add(_instanceHeader(entry.instance));
          rows.addAll(entry.groups.map(_groupTile));
        }

        return ListView(children: rows);
      },
    );
  }

  Widget _instanceHeader(KrabInstance instance) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          instance.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
                letterSpacing: GlobalThemeData.mediumTracking,
              ),
        ),
      );

  Widget _groupTile(Group group) {
    final key = UserPreferences.groupKey(group.instanceId, group.id);
    return CheckboxListTile(
      secondary: GroupAvatar(group, radius: 18),
      title: Text(group.name),
      value: _selected.contains(key),
      onChanged: (value) => setState(() {
        if (value == true) {
          _selected.add(key);
        } else {
          _selected.remove(key);
        }
      }),
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
            child: GestureDetector(
              onTap: _openPreview,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(widget.imageFile, fit: BoxFit.cover),
              ),
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
            GestureDetector(
              onTap: _openPreview,
              child: Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  image: DecorationImage(
                      image: FileImage(widget.imageFile), fit: BoxFit.cover),
                ),
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
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: isLandscape ? null : Text(context.l10n.select_groups),
      contentPadding: (isLandscape && keyboardOpen)
          ? EdgeInsets.zero
          : isLandscape
              ? const EdgeInsets.fromLTRB(16, 16, 16, 0)
              : const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      actionsPadding: isLandscape
          ? const EdgeInsets.fromLTRB(16, 4, 16, 8)
          : const EdgeInsets.fromLTRB(20, 0, 20, 20),
      content: SizedBox(
        width: screenWidth,
        child: LayoutBuilder(
          builder: (_, cst) {
            // Reserve room for description + spacer + safety margin.
            final gh = cst.maxHeight.isFinite
                ? (cst.maxHeight - spacerH - 88).clamp(0.0, double.infinity)
                : (MediaQuery.sizeOf(context).height * 0.5).clamp(60.0, 500.0);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Visibility(
                    visible: !(isLandscape && keyboardOpen),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: gh),
                      child: dialogContent,
                    ),
                  ),
                ),
                SizedBox(height: spacerH),
                RoundedInputField(
                  hintText: context.l10n.add_description,
                  capitalizeSentences: true,
                  controller: _description,
                  maxLength: maxDescriptionLength,
                  minLines: 1,
                  maxLines: 4,
                ),
              ],
            );
          },
        ),
      ),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: () => Navigator.of(context).pop(),
          label: context.l10n.cancel,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            onPressed: _selected.isEmpty ? null : _send,
            label: context.l10n.send,
            icon: Icons.send_rounded,
            color: _selected.isEmpty
                ? Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.4)
                : Theme.of(context).colorScheme.primary,
          ),
      ],
    );
  }
}
