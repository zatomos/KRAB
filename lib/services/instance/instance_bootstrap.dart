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
///
/// The payload names it, so a message can be routed to the right server no
/// matter which one the UI happens to be showing. Messages sent before the
/// backend started stamping `instance_id` fall back to the active instance,
/// which is correct while this install has only one.
KrabInstance? instanceForPayload(Map<String, String> data) {
  final registry = InstanceRegistry.instance;
  return registry.byId(data['instance_id']) ?? registry.active;
}
