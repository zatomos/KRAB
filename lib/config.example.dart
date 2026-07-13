/// Build-time configuration. Copy this file before building:
///
///   cp lib/config.example.dart lib/config.dart
library;

/// The GitHub repository this build checks for its own updates.
///Point this at *your* repository. Left empty, the app never checks for
/// updates.
const updateRepo = '';

/// Whether the app checks for updates at all.
const enableAutoUpdate = false;

/// Optionally pre-point this build at one KRAB instance, so its users skip the
/// connect screen.
const bakedSupabaseUrl = '';
const bakedSupabaseAnonKey = '';
