import 'package:flutter/widgets.dart';

import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/instance/krab_instance.dart';
import 'package:krab/user_preferences.dart';

/// Bring the instance registry up in this isolate and load every session it
/// holds. Each isolate has its own copy of all of it; storage is what they
/// agree on.
///
/// Returns whether this install is connected to any backend at all.
Future<bool> loadInstances() async {
  await InstanceRegistry.instance.load();
  await InstanceRegistry.instance.loadSessions();
  return !InstanceRegistry.instance.isEmpty;
}

/// Common boot sequence for background isolates.
Future<void> bootstrapBackgroundIsolate() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserPreferences().initPrefs();
  await DebugNotifier.instance.initialize();
  await loadInstances();
}

/// The instance a push belongs to.
KrabInstance? instanceForPayload(Map<String, String> data, {String? senderId}) {
  final registry = InstanceRegistry.instance;

  final url = _normalize(data['instance_url']);
  if (url != null) {
    for (final instance in registry.all) {
      if (_normalize(instance.url) == url) return instance;
    }
    debugPrint('Push: no instance matches $url, falling back to sender/sole');
  }

  if (senderId != null && senderId.isNotEmpty) {
    final matches =
        registry.all.where((i) => i.config.fcmSenderId == senderId).toList();
    if (matches.length == 1) return matches.first;
  }

  return registry.sole;
}

String? _normalize(String? url) {
  if (url == null) return null;
  var trimmed = url.trim().toLowerCase();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed.isEmpty ? null : trimmed;
}
