import 'package:flutter/widgets.dart';

/// Non-web fallback for [buildInlineWebView].
///
/// Android has no in-process viewer for an arbitrary URL, and adding a PDF
/// rendering dependency for a console that is used on the web is not worth the
/// weight. Returning null tells the caller to offer the file as a link instead.
Widget? buildInlineWebView(String url) => null;
