/// Embeds a URL directly in the page where the platform can do it.
///
/// A PDF is the common case: the browser already has a viewer, so the reviewer
/// can read the document in place instead of being sent to another tab. Returns
/// null where there is no such viewer, which lets the caller fall back to a
/// filename and a link rather than showing an empty box.
library;

export 'inline_web_view_stub.dart'
    if (dart.library.js_interop) 'inline_web_view_web.dart';
