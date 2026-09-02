/// Saves a text file to the user's device where the platform supports it.
///
/// `downloadTextFile` returns false when there is nowhere to save to, so
/// callers can fall back to showing the content instead of silently doing
/// nothing.
library;

export 'file_download_stub.dart' if (dart.library.js_interop) 'file_download_web.dart';
