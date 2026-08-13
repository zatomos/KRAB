import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/frosted_palette.dart';

/// Actions offered by the viewer's overflow menu.
enum ViewerAction { save, editDescription, addToGroups, delete }

Future<ViewerAction?> showViewerActionsMenu(
  BuildContext context, {
  required GlobalKey buttonKey,
  required bool isOwner,
  required bool canModerate,
}) async {
  final button = buttonKey.currentContext?.findRenderObject() as RenderBox?;
  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (button == null || overlayBox == null) return null;

  // Bottom-right corner of the button, in overlay coordinates.
  final anchor = button.localToGlobal(
    button.size.bottomRight(Offset.zero),
    ancestor: overlayBox,
  );

  return showGeneralDialog<ViewerAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    transitionBuilder: (dialogContext, animation, _, __) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return Stack(
        children: [
          Positioned(
            top: anchor.dy + 8,
            right: overlayBox.size.width - anchor.dx,
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
                alignment: Alignment.topRight,
                child: _ActionsPanel(
                  isOwner: isOwner,
                  canModerate: canModerate,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _ActionsPanel extends StatelessWidget {
  final bool isOwner;
  final bool canModerate;

  const _ActionsPanel({required this.isOwner, required this.canModerate});

  @override
  Widget build(BuildContext context) {
    final divider = Container(
      height: 1,
      color: frostedOn.withValues(alpha: 0.08),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Material(
          color: context.frostedTintStrong,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: context.frostedBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MenuItem(
                  icon: Symbols.download_rounded,
                  label: context.l10n.save_to_device,
                  value: ViewerAction.save,
                ),
                if (isOwner) ...[
                  divider,
                  _MenuItem(
                    icon: Symbols.edit_rounded,
                    label: context.l10n.edit_description,
                    value: ViewerAction.editDescription,
                  ),
                  divider,
                  _MenuItem(
                    icon: Symbols.group_add_rounded,
                    label: context.l10n.add_to_group,
                    value: ViewerAction.addToGroups,
                  ),
                ],
                if (isOwner || canModerate) ...[
                  divider,
                  _MenuItem(
                    icon: Symbols.delete_rounded,
                    label: context.l10n.delete,
                    value: ViewerAction.delete,
                    destructive: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final ViewerAction value;
  final bool destructive;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.value,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? frostedError : frostedOn;
    return InkWell(
      onTap: () => Navigator.of(context).pop(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
