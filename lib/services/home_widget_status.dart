import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/SoftButton.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/l10n/l10n.dart';

class HomeWidgetStatus {
  // Singleton
  static final HomeWidgetStatus instance = HomeWidgetStatus._();
  HomeWidgetStatus._();

  // Channels
  static const MethodChannel _pinChannel = MethodChannel("krab/widget_pin");
  static const MethodChannel _eventsChannel =
      MethodChannel("krab/widget_pin_events");

  // Callback for widget installed changes
  VoidCallback? _onWidgetInstalledChanged;

  BuildContext? _activeContext;

  void initialize() {
    _eventsChannel.setMethodCallHandler((call) async {
      debugPrint("Method call received: ${call.method}");

      if (call.method == "onWidgetPinned") {
        debugPrint("Widget pinned callback received!");

        // Notify UI
        _onWidgetInstalledChanged?.call();

        // Wait for Android to fully register the widget
        await Future.delayed(const Duration(milliseconds: 500));

        // Show snackbar
        if (_activeContext != null && _activeContext!.mounted) {
          showSnackBar(_activeContext!.l10n.widget_added_success,
              color: Colors.green);
        } else {
          debugPrint("Cannot show snackbar");
        }
      }
    });
  }

  // Allows UI widgets to subscribe to widget installation changes
  void setWidgetInstalledListener(VoidCallback callback) {
    _onWidgetInstalledChanged = callback;
  }

  // Check if Krab widget is installed
  Future<bool> hasKrabWidget() async {
    if (!Platform.isAndroid) return false;

    final widgets = await HomeWidget.getInstalledWidgets();
    debugPrint("Installed widgets: $widgets");

    return widgets.isNotEmpty;
  }

  // Show dialog asking user to add widget
  Future<void> showWidgetPromptIfNeeded(BuildContext context) async {
    if (!context.mounted) return;

    final hasWidget = await hasKrabWidget();
    if (!context.mounted) return;
    if (hasWidget) return;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.add_krab_widget),
        content: Text(context.l10n.krab_widget_experience_desc),
        actions: [
          SoftButton(
            label: context.l10n.later,
            color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
            onPressed: () => Navigator.pop(dialogContext),
          ),
          SoftButton(
            label: context.l10n.add_widget,
            color: GlobalThemeData.darkColorScheme.primary,
            onPressed: () {
              Navigator.pop(dialogContext);
              pickWidgetConfig(context);
            },
          ),
        ],
      ),
    );
  }

  // Let user choose config
  Future<void> pickWidgetConfig(BuildContext context) async {
    if (!context.mounted) return;

    // Store context for snackbar
    _activeContext = context;

    final supported = await HomeWidget.isRequestPinWidgetSupported() ?? false;
    if (!context.mounted) return;

    if (!supported) {
      showManualAddInstructions(context);
      return;
    }

    final showText = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.widget_configuration),
        content: Text(context.l10n.widget_configuration_desc),
        actions: [
          SoftButton(
            label: context.l10n.image_only,
            color: GlobalThemeData.darkColorScheme.primary,
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          SoftButton(
            label: context.l10n.image_with_description,
            color: GlobalThemeData.darkColorScheme.primary,
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );

    if (showText == null) return;

    await requestWidgetPin(showText);
  }

  // Trigger the pin request
  Future<void> requestWidgetPin(bool showText) async {
    if (!Platform.isAndroid) return;

    try {
      await _pinChannel.invokeMethod("pinWidget", {
        "showText": showText,
      });
    } catch (e) {
      debugPrint("Error pinning widget: $e");
    }
  }

  // Manual add instructions fallback
  void showManualAddInstructions(BuildContext context) {
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.widgets),
            const SizedBox(width: 10),
            Expanded(child: Text(context.l10n.add_krab_widget)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle(context.l10n.follow_these_steps),
              const SizedBox(height: 15),
              _step('1', context.l10n.krab_widget_instruction_1),
              const SizedBox(height: 10),
              _step('2', context.l10n.krab_widget_instruction_2),
              const SizedBox(height: 10),
              _step('3', context.l10n.krab_widget_instruction_3),
              const SizedBox(height: 10),
              _step('4', context.l10n.krab_widget_instruction_4),
              const SizedBox(height: 15),
              _infoBox(context.l10n.steps_vary_launcher),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.got_it),
          ),
        ],
      ),
    );
  }

  // UI helpers
  Widget _sectionTitle(String text) => Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      );

  Widget _step(String number, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: GlobalThemeData.darkColorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(number,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  )),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      );

  Widget _infoBox(String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blue.withValues(alpha: 0.3))),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.blue[300], size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}
