import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';

/// A short shortlist of common reactions
const List<String> _recommendedEmojis = [
  '❤️', '👍', '👎', '😂', '😮', '😢', '🔥', '🎉', '👏',
];

/// Present the emoji picker as a bottom sheet. Resolves to the chosen emoji, or
/// null if dismissed without a selection.
Future<String?> showEmojiPicker(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final pickerHeight =
      (MediaQuery.sizeOf(context).height * 0.4).clamp(280.0, 380.0);

  final pickerKey = GlobalKey<EmojiPickerState>();
  final config = Config(
    height: pickerHeight,
    emojiViewConfig: EmojiViewConfig(
      backgroundColor: scheme.surface,
      columns: 8,
      emojiSizeMax: 28,
      noRecents: Text(
        context.l10n.no_recents,
        style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      ),
    ),
    categoryViewConfig: CategoryViewConfig(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primary,
      iconColor: scheme.onSurfaceVariant,
      iconColorSelected: scheme.primary,
      backspaceColor: scheme.primary,
      dividerColor: scheme.outlineVariant,
    ),
    bottomActionBarConfig: BottomActionBarConfig(
      backgroundColor: scheme.surfaceContainerHighest,
      buttonColor: scheme.surfaceContainerHighest,
      buttonIconColor: scheme.onSurfaceVariant,
      showBackspaceButton: false,
    ),
    searchViewConfig: SearchViewConfig(
      backgroundColor: scheme.surface,
      buttonIconColor: scheme.onSurface,
    ),
  );

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      // Record quick access taps in the package's recently used list
      Future<void> pickQuick(String emoji) async {
        final navigator = Navigator.of(sheetContext);
        await EmojiPickerUtils().addEmojiToRecentlyUsed(
          key: pickerKey,
          emoji: Emoji(emoji, ''),
          config: config,
        );
        navigator.pop(emoji);
      }

      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  sheetContext.l10n.quick_access_emoji,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                height: 48,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _recommendedEmojis.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 4),
                  itemBuilder: (context, i) {
                    final emoji = _recommendedEmojis[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => pickQuick(emoji),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child:
                              Text(emoji, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              SizedBox(
                height: pickerHeight,
                child: EmojiPicker(
                  key: pickerKey,
                  onEmojiSelected: (category, emoji) =>
                      Navigator.of(sheetContext).pop(emoji.emoji),
                  config: config,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
