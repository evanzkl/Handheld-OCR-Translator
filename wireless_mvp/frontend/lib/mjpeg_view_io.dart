/// Live MJPEG preview from the ESP32 `/stream` endpoint for Android / desktop / tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class MjpegView extends StatefulWidget {
  const MjpegView({super.key, required this.streamUrl});

  final String streamUrl;

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  HttpClient? _client;
  Uint8List? _frame;
  String? _error;
  Timer? _reconnectTimer;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MjpegView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl) {
      _start();
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _client?.close(force: true);
    _client = null;
  }

  void _start() {
    _stop();
    if (WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding')) {
      return;
    }
    unawaited(_listen(_generation));
  }

  void _scheduleReconnect(int generation) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted || generation != _generation) return;
      unawaited(_listen(generation));
    });
  }

  Future<void> _listen(int generation) async {
    final uri = Uri.tryParse(widget.streamUrl);
    if (uri == null || uri.host.isEmpty) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = 'Invalid camera stream URL.');
      return;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 15);
    _client = client;

    try {
      final request = await client.getUrl(uri);
      if (!mounted || generation != _generation) return;
      request.headers.set(HttpHeaders.acceptHeader, 'multipart/x-mixed-replace');
      final response = await request.close();
      if (!mounted || generation != _generation) return;
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Camera stream HTTP ${response.statusCode}', uri: uri);
      }

      if (mounted && generation == _generation) {
        setState(() => _error = null);
      }

      final parser = _MjpegStreamParser();
      await for (final chunk in response) {
        if (!mounted || generation != _generation) return;
        parser.add(chunk);
        Uint8List? frame;
        while (true) {
          final next = parser.takeFrame();
          if (next == null) break;
          frame = next;
        }
        if (frame != null && mounted && generation == _generation) {
          setState(() {
            _frame = frame;
            _error = null;
          });
        }
      }
      if (!mounted || generation != _generation) return;
      _scheduleReconnect(generation);
    } catch (exc) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = 'Could not reach camera stream at ${widget.streamUrl}\n$exc';
      });
      _scheduleReconnect(generation);
    } finally {
      client.close(force: true);
      if (identical(_client, client)) {
        _client = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    if (frame != null) {
      return Image.memory(
        frame,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        excludeFromSemantics: true,
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _error ?? 'Connecting to camera stream...',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}

/// Pulls JPEG payloads out of the firmware multipart stream using Content-Length.
class _MjpegStreamParser {
  static const _maxBufferBytes = 2 * 1024 * 1024;
  static const _headerEnd = [0x0d, 0x0a, 0x0d, 0x0a];
  static final _contentLength = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false);

  final List<int> _buffer = <int>[];

  void add(List<int> chunk) {
    _buffer.addAll(chunk);
    if (_buffer.length > _maxBufferBytes) {
      _buffer.removeRange(0, _buffer.length - 64);
    }
  }

  Uint8List? takeFrame() {
    while (true) {
      final headerEnd = _indexOf(_headerEnd);
      if (headerEnd == null) return null;

      final header = ascii.decode(_buffer.sublist(0, headerEnd), allowInvalid: true);
      final match = _contentLength.firstMatch(header);
      if (match == null) {
        _buffer.removeRange(0, headerEnd + _headerEnd.length);
        continue;
      }

      final length = int.parse(match.group(1)!);
      final dataStart = headerEnd + _headerEnd.length;
      if (_buffer.length < dataStart + length) return null;

      final frame = Uint8List.fromList(_buffer.sublist(dataStart, dataStart + length));
      _buffer.removeRange(0, dataStart + length);
      return frame;
    }
  }

  int? _indexOf(List<int> pattern) {
    final limit = _buffer.length - pattern.length;
    for (var i = 0; i <= limit; i++) {
      var found = true;
      for (var j = 0; j < pattern.length; j++) {
        if (_buffer[i + j] != pattern[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return null;
  }
}
