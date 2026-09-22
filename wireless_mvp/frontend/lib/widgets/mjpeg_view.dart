import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Renders a live MJPEG stream (multipart/x-mixed-replace) directly from the
/// ESP32. Flutter has no built-in MJPEG widget, so this scans the byte stream
/// for JPEG SOI/EOI markers rather than parsing multipart boundaries/headers.
class MjpegView extends StatefulWidget {
  const MjpegView({super.key, required this.streamUrl, this.onFrame});

  final String streamUrl;

  /// Invoked with each decoded JPEG frame as it arrives.
  final ValueChanged<Uint8List>? onFrame;

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  http.Client? _client;
  StreamSubscription<List<int>>? _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Uint8List? _frame;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(covariant MjpegView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl) {
      _disconnect();
      _connect();
    }
  }

  Future<void> _connect() async {
    final client = http.Client();
    _client = client;
    setState(() {
      _frame = null;
      _error = null;
    });
    try {
      final request = http.Request('GET', Uri.parse(widget.streamUrl));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        if (mounted) setState(() => _error = 'ESP32 stream returned HTTP ${response.statusCode}');
        return;
      }
      _subscription = response.stream.listen(
        _onChunk,
        onError: (Object exc) {
          if (mounted) setState(() => _error = 'Stream error: $exc');
        },
        onDone: () {
          if (mounted) setState(() => _error = 'Stream closed');
        },
        cancelOnError: true,
      );
    } catch (exc) {
      if (mounted) setState(() => _error = 'Could not reach ESP32 stream: $exc');
    }
  }

  void _onChunk(List<int> chunk) {
    _buffer.add(chunk);
    final data = _buffer.toBytes();
    final start = _indexOf(data, const [0xFF, 0xD8]);
    if (start == -1) {
      return;
    }
    final end = _indexOf(data, const [0xFF, 0xD9], start + 2);
    if (end == -1) {
      // Incomplete frame so far: keep only the bytes from the start marker onward.
      _buffer.clear();
      _buffer.add(data.sublist(start));
      return;
    }
    final frame = Uint8List.fromList(data.sublist(start, end + 2));
    _buffer.clear();
    if (end + 2 < data.length) {
      _buffer.add(data.sublist(end + 2));
    }
    widget.onFrame?.call(frame);
    if (mounted) {
      setState(() {
        _frame = frame;
        _error = null;
      });
    }
  }

  int _indexOf(Uint8List data, List<int> pattern, [int from = 0]) {
    for (var i = from; i <= data.length - pattern.length; i++) {
      var found = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }

  void _disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
    _buffer.clear();
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    if (_frame == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.contain);
  }
}
