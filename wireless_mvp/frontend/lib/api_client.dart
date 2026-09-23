import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class OcrApiException implements Exception {
  OcrApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

const int kDefaultBackendPort = 8000;

/// Ensures scheme + port 8000 when the user types a bare LAN IP like `10.0.0.161`.
String normalizeBackendUrl(String raw, {int defaultPort = kDefaultBackendPort}) {
  var text = raw.trim();
  if (text.isEmpty) return text;
  if (!text.contains('://')) {
    text = 'http://$text';
  }
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return text;
  return Uri(
    scheme: uri.scheme.isEmpty ? 'http' : uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : defaultPort,
  ).toString();
}

bool isLoopbackBackendUrl(String raw) {
  final host = Uri.tryParse(normalizeBackendUrl(raw))?.host.toLowerCase() ?? '';
  return host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '10.0.2.2';
}

class OcrApiClient {
  OcrApiClient({required this.baseUrl});

  final String baseUrl;

  String get _root => normalizeBackendUrl(baseUrl);

  Future<List<LanguageInfo>> fetchLanguages() async {
    final response = await http.get(Uri.parse('$_root/api/languages'));
    if (response.statusCode != 200) {
      throw OcrApiException(_detail(response) ?? 'Could not load languages (HTTP ${response.statusCode}).');
    }
    final data = jsonDecode(response.body);
    if (data is! List) {
      throw OcrApiException('Unexpected languages response.');
    }
    return data.map((item) => LanguageInfo.fromJson(item as Map<String, dynamic>)).toList();
  }

  Future<ProcessResult> processImage({
    required Uint8List imageBytes,
    required String filename,
    required String sourceLang,
    required String targetLang,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$_root/api/process'))
      ..files.add(http.MultipartFile.fromBytes('file', imageBytes, filename: filename))
      ..fields['source_lang'] = sourceLang
      ..fields['target_lang'] = targetLang;
    return _readProcessResult(await http.Response.fromStream(await request.send()));
  }

  Future<String> createJob({
    required String sourceLang,
    required String targetLang,
  }) async {
    final response = await http.post(
      Uri.parse('$_root/api/v1/jobs'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'source_lang': sourceLang,
        'target_lang': targetLang,
      }),
    );
    if (response.statusCode != 200) {
      throw OcrApiException(_detail(response) ?? 'Could not create capture job (HTTP ${response.statusCode}).');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final jobId = data['job_id'] as String?;
    if (jobId == null || jobId.isEmpty) {
      throw OcrApiException('Backend did not return a job_id.');
    }
    return jobId;
  }

  Future<JobStatus> getJob(String jobId) async {
    final response = await http.get(Uri.parse('$_root/api/v1/jobs/$jobId'));
    if (response.statusCode != 200) {
      throw OcrApiException(_detail(response) ?? 'Could not read job status (HTTP ${response.statusCode}).');
    }
    return JobStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<ProcessResult> waitForJob(
    String jobId, {
    Duration timeout = const Duration(minutes: 2),
    Duration pollInterval = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final job = await getJob(jobId);
      if (job.status == 'done') {
        final result = job.result;
        if (result == null) {
          throw OcrApiException('Job finished without an image.');
        }
        return result;
      }
      if (job.status == 'error') {
        throw OcrApiException(job.error ?? 'Capture job failed.');
      }
      await Future<void>.delayed(pollInterval);
    }
    throw OcrApiException('Timed out waiting for the ESP32 capture to finish.');
  }

  Future<void> triggerEsp32Upload({
    required String esp32Url,
    required String jobId,
    required String backendUrl,
  }) async {
    final response = await http
        .post(
          Uri.parse('$_root/api/v1/jobs/$jobId/trigger'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'esp32_url': esp32Url.trim(),
            'backend_url': normalizeBackendUrl(backendUrl),
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw OcrApiException(_detail(response) ?? 'ESP32 capture failed (HTTP ${response.statusCode}).');
    }
  }

  Future<bool> pollEsp32CaptureButton(String esp32Url) async {
    try {
      final uri = Uri.parse('$_root/api/v1/esp32/button_event').replace(
        queryParameters: {'esp32_url': esp32Url.trim()},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body);
      return data is Map && data['capture_requested'] == true;
    } catch (_) {
      return false;
    }
  }

  ProcessResult _readProcessResult(http.Response response) {
    if (response.statusCode != 200) {
      throw OcrApiException(_detail(response) ?? 'Request failed (HTTP ${response.statusCode}).');
    }
    return ProcessResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  String? _detail(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data is Map && data['detail'] != null) return data['detail'].toString();
      if (data is Map && data['message'] != null) return data['message'].toString();
    } catch (_) {
      // Body was not JSON.
    }
    return null;
  }
}
