import 'package:web/web.dart' as web;

/// Hands the browser a file to save.
///
/// A data: URI rather than a Blob — the payload here is a few hundred bytes of
/// CSV, and this avoids both the object-URL lifetime and the JS array
/// conversions a Blob would need. An anchor carrying `download` is treated as a
/// save rather than a navigation, which is what keeps Chrome from blocking it.
bool downloadTextFile(String fileName, String content) {
  final anchor = web.HTMLAnchorElement()
    ..href = 'data:text/csv;charset=utf-8,${Uri.encodeComponent(content)}'
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  return true;
}
