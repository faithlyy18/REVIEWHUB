// Non-web platforms (Android, iOS, Windows, macOS, Linux): Google's JS
// Drive Picker widget only runs inside a browser, so it isn't available
// here. modules_screen.dart checks `kIsWeb`/`isDrivePickerSupported` before
// ever calling showGoogleDrivePicker, so this body never actually runs — it
// exists only so the conditional import in google_drive_picker.dart compiles
// on every platform. Non-web platforms fall back to the in-app Drive file
// list (_DriveFilePickerSheet in modules_screen.dart) instead.

class DrivePickerResult {
  final String id;
  final String name;
  const DrivePickerResult({required this.id, required this.name});
}

const bool isDrivePickerSupported = false;

Future<DrivePickerResult?> showGoogleDrivePicker({
  required String accessToken,
  String apiKey = '',
}) {
  throw UnsupportedError('showGoogleDrivePicker is only available on web.');
}
