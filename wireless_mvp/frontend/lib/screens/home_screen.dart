import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/job_status.dart';
import '../models/language.dart';
import '../models/process_result.dart';
import '../services/backend_client.dart';
import '../services/esp32_client.dart';
import '../widgets/mjpeg_view.dart';
import '../widgets/pill_button.dart';

/// Mirrors laptop_mvp/gui/result_view.py's _confidence_label().
String _confidenceLabel(double accuracy) {
  if (accuracy >= 90) return 'High Confidence';
  if (accuracy >= 70) return 'Medium Confidence';
  return 'Low Confidence';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  BackendClient _client = BackendClient(baseUrl: 'http://localhost:8000');
  final _backendUrlController = TextEditingController(text: 'http://localhost:8000');
  final _esp32UrlController = TextEditingController(text: 'http://esp32cam.local');
  Timer? _buttonPollTimer;

  bool _uiVisible = true;

  /// Last frame received from the live view, used as the frozen/darkened
  /// backdrop while processing (mirrors laptop_mvp/gui's freeze_and_show_processing()).
  Uint8List? _lastLiveFrame;
  Uint8List? _frozenBytes;

  /// Live-view FPS: frames are tallied in onFrame and the rate is recomputed
  /// once per second (rather than on every frame) to avoid excess rebuilds.
  int _liveFrameCount = 0;
  double _liveFps = 0;
  Timer? _fpsTimer;

  List<Language> _languages = [];
  Language? _sourceLanguage;
  Language? _targetLanguage;

  Uint8List? _pickedBytes;
  String? _pickedFilename;

  ProcessResult? _result;
  bool _loadingLanguages = true;
  bool _processing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadLanguages();
    _buttonPollTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => _pollPhysicalButton());
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _liveFps = _liveFrameCount.toDouble();
        _liveFrameCount = 0;
      });
    });
  }

  @override
  void dispose() {
    _backendUrlController.dispose();
    _esp32UrlController.dispose();
    _fpsTimer?.cancel();
    _buttonPollTimer?.cancel();
    super.dispose();
  }

  /// The physical button mirrors whichever GUI button is currently shown:
  /// "Capture Image" in the live/camera state, "Retake" once a result is displayed.
  Future<void> _pollPhysicalButton() async {
    if (_esp32UrlController.text.trim().isEmpty) {
      return;
    }
    try {
      final pressed = await Esp32Client(baseUrl: _esp32UrlController.text.trim()).pollButtonEvent();
      if (!pressed || !mounted || _processing) {
        return;
      }
      if (_result != null) {
        _retake();
      } else {
        await _captureFromEsp32();
      }
    } catch (_) {
      // The live stream widget displays connection errors; polling stays quiet while the ESP32 is offline.
    }
  }

  void _applyBackendUrl() {
    final url = _backendUrlController.text.trim();
    if (url.isEmpty) {
      return;
    }
    setState(() {
      _client = BackendClient(baseUrl: url);
      _loadingLanguages = true;
      _errorMessage = null;
    });
    _loadLanguages();
  }

  Future<void> _loadLanguages() async {
    try {
      final languages = await _client.fetchLanguages();
      setState(() {
        _languages = languages;
        _sourceLanguage = languages.isNotEmpty ? languages.first : null;
        _targetLanguage = languages.length > 1 ? languages[1] : _sourceLanguage;
        _loadingLanguages = false;
      });
    } catch (exc) {
      setState(() {
        _errorMessage = exc.toString();
        _loadingLanguages = false;
      });
    }
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png'],
    );
    if (result.isEmpty) {
      return;
    }
    final file = result.single;
    final bytes = await file.readAsBytes();
    setState(() {
      _pickedBytes = bytes;
      _pickedFilename = file.name;
      _result = null;
      _errorMessage = null;
    });
  }

  void _swapLanguages() {
    if (_sourceLanguage == null || _targetLanguage == null) {
      return;
    }
    setState(() {
      final swap = _sourceLanguage;
      _sourceLanguage = _targetLanguage;
      _targetLanguage = swap;
    });
  }

  Future<void> _translate() async {
    if (_pickedBytes == null || _sourceLanguage == null || _targetLanguage == null) {
      setState(() => _errorMessage = 'Choose an image and both languages first.');
      return;
    }
    setState(() {
      _processing = true;
      _frozenBytes = _pickedBytes;
      _errorMessage = null;
    });
    try {
      final result = await _client.processImage(
        bytes: _pickedBytes!,
        filename: _pickedFilename ?? 'upload.png',
        sourceLang: _sourceLanguage!.displayName,
        targetLang: _targetLanguage!.displayName,
      );
      setState(() => _result = result);
    } catch (exc) {
      setState(() => _errorMessage = exc.toString());
    } finally {
      setState(() => _processing = false);
    }
  }

  /// Captured-image path: create a job on the backend, tell the ESP32 to
  /// capture (it uploads directly to the backend, not through Flutter), then
  /// poll for the completed result.
  Future<void> _captureFromEsp32() async {
    final esp32Url = _esp32UrlController.text.trim();
    final backendUrl = _backendUrlController.text.trim();
    if (esp32Url.isEmpty) {
      setState(() => _errorMessage = 'Enter the ESP32 base URL first (e.g. http://192.168.1.60).');
      return;
    }
    if (_sourceLanguage == null || _targetLanguage == null) {
      setState(() => _errorMessage = 'Choose both languages first.');
      return;
    }
    final backendHost = Uri.tryParse(backendUrl)?.host.toLowerCase();
    if (backendHost == 'localhost' || backendHost == '127.0.0.1') {
      setState(() => _errorMessage =
          'Backend URL is set to localhost, which the ESP32 cannot reach. '
          'Set it to this computer\'s LAN IP (e.g. http://10.0.0.90:8000) in Settings.');
      return;
    }
    setState(() {
      _processing = true;
      _frozenBytes = _lastLiveFrame;
      _errorMessage = null;
      _result = null;
    });
    try {
      final jobId = await _client.createJob(
        sourceLang: _sourceLanguage!.displayName,
        targetLang: _targetLanguage!.displayName,
      );
      await Esp32Client(baseUrl: esp32Url).triggerCapture(jobId: jobId, backendBaseUrl: backendUrl);

      JobStatus status;
      do {
        await Future.delayed(const Duration(milliseconds: 700));
        status = await _client.fetchJob(jobId);
      } while (status.status == 'pending');

      if (status.status == 'done' && status.result != null) {
        setState(() => _result = status.result);
      } else {
        setState(() => _errorMessage = status.error ?? 'ESP32 capture failed.');
      }
    } catch (exc) {
      setState(() => _errorMessage = exc.toString());
    } finally {
      setState(() => _processing = false);
    }
  }

  /// Mirrors laptop_mvp/gui/app.py's retake(): clear the result and go back to
  /// the live/camera state.
  void _retake() {
    setState(() {
      _result = null;
      _pickedBytes = null;
      _pickedFilename = null;
      _frozenBytes = null;
      _errorMessage = null;
    });
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Connection Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _backendUrlController,
              decoration: const InputDecoration(
                labelText: 'Backend URL (LAN-reachable)',
                helperText: 'Use this computer\'s LAN IP, e.g. http://10.0.0.90:8000 (not localhost) so the ESP32 can reach it',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _esp32UrlController,
              decoration: const InputDecoration(labelText: 'ESP32 camera URL'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _applyBackendUrl();
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingLanguages) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));
    }

    final showingResult = _result != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildBackground()),
            if (_errorMessage != null)
              Positioned(top: 8, left: 16, right: 16, child: _buildErrorBanner()),
            Positioned(left: 18, top: 18, child: _buildEyeToggle()),
            Positioned(right: 18, top: 18, child: CircleIconButton(icon: Icons.settings, onPressed: _openSettings)),
            if (!showingResult && !_processing && _pickedBytes == null)
              Positioned(left: 12, bottom: 12, child: _buildFpsBadge()),
            if (_uiVisible)
              Positioned(
                top: 22,
                left: 0,
                right: 0,
                child: Center(child: showingResult ? _buildResultHud() : _buildCameraHud()),
              ),
          ],
        ),
      ),
    );
  }

  /// Live-view frame rate, sampled once per second from the MJPEG stream.
  Widget _buildFpsBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '${_liveFps.toStringAsFixed(0)} FPS',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
      ),
    );
  }

  Widget _buildBackground() {
    if (_result != null) {
      return Image.memory(base64Decode(_result!.imageBase64), fit: BoxFit.contain);
    }
    if (_processing) {
      return _buildFrozenOverlay(_frozenBytes);
    }
    if (_pickedBytes != null) {
      return Image.memory(_pickedBytes!, fit: BoxFit.contain);
    }
    final esp32Url = _esp32UrlController.text.trim();
    if (esp32Url.isEmpty) {
      return const Center(
        child: Text(
          'Enter the ESP32 camera URL in Settings to see the live view.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    return MjpegView(
      streamUrl: Esp32Client(baseUrl: esp32Url).streamUrl,
      onFrame: (frame) {
        _lastLiveFrame = frame;
        _liveFrameCount++;
      },
    );
  }

  /// Mirrors laptop_mvp/gui/camera_view.py's freeze_and_show_processing():
  /// a darkened still frame with a centered "Processing..." message.
  Widget _buildFrozenOverlay(Uint8List? bytes) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes != null) Image.memory(bytes, fit: BoxFit.contain) else Container(color: Colors.grey.shade900),
        Container(color: Colors.black.withValues(alpha: 0.45)),
        const Center(
          child: Text(
            'Processing...',
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
      child: Text(_errorMessage!, style: TextStyle(color: Colors.red.shade900)),
    );
  }

  Widget _buildEyeToggle() {
    return CircleIconButton(
      icon: _uiVisible ? Icons.visibility : Icons.visibility_off,
      onPressed: () => setState(() => _uiVisible = !_uiVisible),
    );
  }

  /// Mirrors laptop_mvp/gui/camera_view.py's HUD row: language pickers + swap
  /// + capture/upload pill buttons, centered near the top. The live feed
  /// itself is always shown automatically as the background (no toggle needed).
  Widget _buildCameraHud() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 150,
          child: HudDropdown<Language>(
            value: _sourceLanguage,
            items: _languages,
            itemLabel: (lang) => lang.displayName,
            onChanged: (lang) => setState(() => _sourceLanguage = lang),
          ),
        ),
        CircleIconButton(icon: Icons.swap_horiz, onPressed: _swapLanguages),
        SizedBox(
          width: 150,
          child: HudDropdown<Language>(
            value: _targetLanguage,
            items: _languages,
            itemLabel: (lang) => lang.displayName,
            onChanged: (lang) => setState(() => _targetLanguage = lang),
          ),
        ),
        PillButton(label: 'Upload Image', icon: Icons.upload_file, onPressed: _processing ? null : _pickImage),
        if (_pickedBytes != null)
          PillButton(label: 'Translate', icon: Icons.translate, busy: _processing, onPressed: _translate),
        PillButton(label: 'Capture', icon: Icons.camera_alt, busy: _processing, onPressed: _captureFromEsp32),
      ],
    );
  }

  /// Mirrors laptop_mvp/gui/result_view.py's HUD row: just Retake + the
  /// accuracy/processing-time readout.
  Widget _buildResultHud() {
    final result = _result!;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PillButton(label: 'Retake', icon: Icons.refresh, onPressed: _retake),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: pillBackground,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: pillBorderColor),
          ),
          child: Text(
            'Accuracy: ${result.accuracy.toStringAsFixed(1)}% (${_confidenceLabel(result.accuracy)})  |  '
            'Processing: ${result.processingTimeSeconds.toStringAsFixed(2)}s',
            style: const TextStyle(color: accuracyForeground, fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
      ],
    );
  }
}
