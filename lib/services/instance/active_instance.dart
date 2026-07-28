import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/instance/krab_instance.dart';

// The API is split into extensions, which are only in scope where their
// library is imported. Re-exported here so a screen needs one import to both
// find its instance and call it.
export 'package:krab/services/api/krab_api.dart';
export 'package:krab/services/instance/krab_instance.dart';

/// The instance the UI is currently working against.
///
/// This is the seam where "which server?" is answered. Today there is one
/// connected instance and every screen means that one, so they read it here
/// rather than each holding their own copy. When the app starts carrying
/// several at once, a screen that shows data from a particular instance passes
/// that instance down instead of calling this — and the compiler finds every
/// place that still needs deciding, because they are exactly the call sites
/// naming [activeInstance] or [api].
///
/// Throws if no backend is configured yet; only reachable from screens that
/// already require one, since the connect screen comes first.
KrabInstance get activeInstance => InstanceRegistry.instance.requireActive;

/// Shorthand for the active instance's API.
KrabApi get api => activeInstance.api;

/// Whether this install is connected to any backend at all.
bool get hasInstance => !InstanceRegistry.instance.isEmpty;
