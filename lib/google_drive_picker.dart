// Picks the right implementation for the current platform: the real Google
// Drive Picker widget on web, or a stub (never actually called — see there)
// on Android/iOS/Windows/macOS/Linux.
export 'google_drive_picker_stub.dart'
    if (dart.library.js_interop) 'google_drive_picker_web.dart';
