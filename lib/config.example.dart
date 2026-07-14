/// Build-time configuration. Copy this file before building:
///
///   cp lib/config.example.dart lib/config.dart
library;

/// The GitHub repository this build checks for its own updates.
/// Point this at *your* repository. Left empty, the app never checks for
/// updates.
const updateRepo = '';

/// The KRAB project itself.
const projectUrl = 'https://github.com/zatomos/KRAB';

/// Whether the app checks for updates at all.
const enableAutoUpdate = false;

/// Optionally pre-point this build at one KRAB instance, so its users skip the
/// connect screen.
const bakedSupabaseUrl = '';
const bakedSupabaseAnonKey = '';

/// How photos are encoded before being sent to the server.
/// Longest edge in pixels, or 0 to leave the photo at full resolution.
const maxUploadDimension = 0;

/// JPEG quality, 1-100.
const uploadJpegQuality = 100;
