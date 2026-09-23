/// Live MJPEG preview from the ESP32 `/stream` endpoint, rendered as an HTML <img>.
library;

// This file is only compiled for web (see the conditional import in main.dart).
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class MjpegView extends StatefulWidget {
  const MjpegView({super.key, required this.streamUrl});

  final String streamUrl;

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'esp32-mjpeg-view-${identityHashCode(this)}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      return html.ImageElement()
        ..src = widget.streamUrl
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'contain';
    });
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
