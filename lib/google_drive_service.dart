import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

/// What we keep after a successful upload to the instructor's Drive.
class DriveUploadResult {
  final String fileId;
  final String fileName;
  final String viewUrl;
  final String accountEmail;

  const DriveUploadResult({
    required this.fileId,
    required this.fileName,
    required this.viewUrl,
    required this.accountEmail,
  });
}

/// Uploads module files straight into an instructor's own Google Drive.
///
/// Uses the narrow `drive.file` scope, so the app can only see/manage files
/// it created itself (never the rest of the user's Drive). Uploads go into a
/// "ReviewHub Modules" folder and are shared as "anyone with the link can
/// view" so students can open them.
///
/// Picking an *existing* Drive file doesn't go through this service at all —
/// modules_screen.dart just opens https://drive.google.com in a new tab/
/// browser window and has the instructor paste the file's share link back,
/// using Drive's own sharing UI.
class GoogleDriveService {
  GoogleDriveService._();

  static const _folderName = 'ReviewHub Modules';
  static const _folderMime = 'application/vnd.google-apps.folder';

  static final GoogleSignIn _signIn =
      GoogleSignIn(scopes: [drive.DriveApi.driveFileScope]);

  /// Email of the Google account currently connected, or null.
  static String? get connectedEmail => _signIn.currentUser?.email;

  /// Opens the Google account chooser. On web this opens a popup, so it must
  /// be called directly from a tap (before any other awaited work).
  static Future<String?> connect() async {
    final account = await _signIn.signIn();
    return account?.email;
  }

  static Future<void> disconnect() async {
    try {
      await _signIn.disconnect();
    } catch (_) {
      await _signIn.signOut();
    }
  }

  static String mimeFor(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  /// Uploads [bytes] to the connected account's Drive and returns a
  /// view-only shareable link. Throws [StateError] if not connected.
  static Future<DriveUploadResult> upload({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final account = _signIn.currentUser;
    final client = await _signIn.authenticatedClient();
    if (account == null || client == null) {
      throw StateError('Google Drive is not connected.');
    }

    try {
      final api = drive.DriveApi(client);
      final folderId = await _ensureFolder(api);

      final created = await api.files.create(
        drive.File()
          ..name = fileName
          ..parents = [folderId],
        uploadMedia: drive.Media(
          Stream<List<int>>.value(bytes),
          bytes.length,
          contentType: mimeFor(fileName),
        ),
        $fields: 'id,name,webViewLink',
      );

      final id = created.id!;
      await _makeViewable(api, id);

      return DriveUploadResult(
        fileId: id,
        fileName: created.name ?? fileName,
        viewUrl: created.webViewLink ?? 'https://drive.google.com/file/d/$id/view',
        accountEmail: account.email,
      );
    } finally {
      client.close();
    }
  }

  static Future<void> _makeViewable(drive.DriveApi api, String id) =>
      api.permissions.create(
        drive.Permission()
          ..type = 'anyone'
          ..role = 'reader',
        id,
      );

  static Future<String> _ensureFolder(drive.DriveApi api) async {
    final existing = await api.files.list(
      q: "name = '$_folderName' and mimeType = '$_folderMime' and trashed = false",
      spaces: 'drive',
      $fields: 'files(id)',
      pageSize: 1,
    );
    final found = existing.files;
    if (found != null && found.isNotEmpty && found.first.id != null) {
      return found.first.id!;
    }
    final folder = await api.files.create(
      drive.File()
        ..name = _folderName
        ..mimeType = _folderMime,
      $fields: 'id',
    );
    return folder.id!;
  }
}
