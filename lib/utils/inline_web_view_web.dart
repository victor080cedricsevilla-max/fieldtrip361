import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// View types already handed to the registry.
///
/// Registering the same type twice throws, and the URL changes on every load
/// because the server mints a fresh one each time, so the type is keyed by URL
/// and remembered here.
final Set<String> _registered = <String>{};

/// Embeds [url] in an iframe so the browser's own PDF viewer renders it inline.
///
/// `sandbox` is set to allow-scripts and allow-same-origin only: the built-in
/// viewer needs both, but the document must not be able to navigate the console
/// it is embedded in. Uploads are untrusted — they come from applicants.
Widget? buildInlineWebView(String url) {
  if (url.isEmpty) return null;
  final viewType = 'ft360-inline-${url.hashCode}';
  if (_registered.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final frame = web.HTMLIFrameElement()
        ..src = url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      frame.setAttribute('sandbox', 'allow-scripts allow-same-origin');
      return frame;
    });
  }
  return HtmlElementView(viewType: viewType);
}
