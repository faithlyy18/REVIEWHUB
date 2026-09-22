// Web-only: launches Google's own Drive Picker widget — the same file
// browser Google Docs/Slides use — instead of a hand-rolled file list.
// Loads Google's API loader script on demand, then Google's `picker` module,
// then opens the picker using the access token from GoogleDriveService.
//
// See google_drive_picker_stub.dart for the (never-called-on-web) fallback
// that lets modules_screen.dart's conditional import compile on every
// platform.
import 'dart:async';
import 'dart:js_interop';

const bool isDrivePickerSupported = true;

class DrivePickerResult {
  final String id;
  final String name;
  const DrivePickerResult({required this.id, required this.name});
}

const _apiScriptSrc = 'https://apis.google.com/js/api.js';

/// Opens Google's Drive Picker for the account [accessToken] belongs to
/// (must have Drive read access — see GoogleDriveService). Resolves with the
/// chosen file, or null if the instructor cancels. [apiKey] is an optional
/// Cloud Console API key (Picker API); pass '' to skip it.
Future<DrivePickerResult?> showGoogleDrivePicker({
  required String accessToken,
  String apiKey = '',
}) async {
  await _ensureApiScriptLoaded();
  await _ensurePickerModuleLoaded();

  final completer = Completer<DrivePickerResult?>();

  void onPickerEvent(_PickerData data) {
    if (completer.isCompleted) return;
    if (data.action == 'picked') {
      final docs = data.docs;
      if (docs != null && docs.length > 0) {
        final doc = docs[0];
        completer.complete(DrivePickerResult(id: doc.id, name: doc.name));
        return;
      }
    }
    // 'cancel', or a 'picked' event with no docs — treat both as "no file".
    completer.complete(null);
  }

  var builder = _PickerBuilder()
      .addView(_DocsView().setIncludeFolders(false))
      .setOAuthToken(accessToken)
      .setCallback(onPickerEvent.toJS);
  if (apiKey.isNotEmpty) {
    builder = builder.setDeveloperKey(apiKey);
  }
  builder.build().setVisible(true);

  return completer.future;
}

Future<void> _ensureApiScriptLoaded() {
  if (_gapiGlobal != null) return Future.value();
  final completer = Completer<void>();
  final script = _jsDocument.createElement('script');
  script.src = _apiScriptSrc;
  script.async = true;
  script.onload = (() => completer.complete()).toJS;
  script.onerror = (() => completer
          .completeError(Exception('Failed to load the Google API script')))
      .toJS;
  _jsDocument.head.appendChild(script);
  return completer.future;
}

Future<void> _ensurePickerModuleLoaded() {
  if (_pickerGlobal != null) return Future.value();
  final completer = Completer<void>();
  _gapiLoadPicker((() => completer.complete()).toJS);
  return completer.future;
}

@JS('gapi')
external JSObject? get _gapiGlobal;

@JS('gapi.load')
external void _gapiLoadPicker(JSFunction callback);

@JS('google.picker')
external JSObject? get _pickerGlobal;

// ── Minimal DOM interop, just enough to inject the loader <script> tag ────

@JS('document')
external _JSDocument get _jsDocument;

extension type _JSDocument._(JSObject _) implements JSObject {
  external _JSElement createElement(String tagName);
  external _JSElement get head;
}

extension type _JSElement._(JSObject _) implements JSObject {
  external set src(String value);
  external set async(bool value);
  external set onload(JSFunction? value);
  external set onerror(JSFunction? value);
  external void appendChild(JSObject node);
}

// ── Google Picker API bindings (https://developers.google.com/drive/picker) ─

@JS('google.picker.PickerBuilder')
extension type _PickerBuilder._(JSObject _) implements JSObject {
  external _PickerBuilder();
  external _PickerBuilder addView(JSObject view);
  external _PickerBuilder setOAuthToken(String token);
  external _PickerBuilder setDeveloperKey(String key);
  external _PickerBuilder setCallback(JSFunction callback);
  external _Picker build();
}

@JS('google.picker.Picker')
extension type _Picker._(JSObject _) implements JSObject {
  external void setVisible(bool visible);
}

@JS('google.picker.DocsView')
extension type _DocsView._(JSObject _) implements JSObject {
  external _DocsView();
  external _DocsView setIncludeFolders(bool include);
}

/// Shape of the object Google's picker passes to the callback: `{action,
/// docs}`, where `action` is `'picked'` or `'cancel'` and `docs` (when
/// present) holds the chosen file(s).
extension type _PickerData._(JSObject _) implements JSObject {
  external String get action;
  external JSArray<_PickerDoc>? get docs;
}

extension type _PickerDoc._(JSObject _) implements JSObject {
  external String get id;
  external String get name;
}
