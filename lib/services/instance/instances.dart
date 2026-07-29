import 'package:krab/services/instance/instance_registry.dart';

export 'package:krab/services/api/krab_api.dart';
export 'package:krab/services/instance/krab_instance.dart';

/// Whether this install is connected to any backend at all.
bool get hasInstance => !InstanceRegistry.instance.isEmpty;

/// Whether the user is signed into any of them.
bool get anySignedIn => InstanceRegistry.instance.anySignedIn;
