import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/job_status.dart';
import '../models/language.dart';
import '../models/process_result.dart';

/// Raised when the backend is unreachable or returns a non-2xx response.
class BackendException implements Exception {
  BackendException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thin HTTP client for the existing FastAPI backend (see wireless_mvp/backend).
///
/// Endpoint contract (verified against backend/main.py, not assumed):
///   GET  /api/languages -> list of {display_name, ocr_code, translate_code}
///   POST /api/process   -> multipart fields: file, source_lang, target_lang
///                          returns {image_base64, image_format, accuracy, processing_time_seconds}
class BackendClient {
  BackendClient({String baseUrl = 'http://localhost:8000'})
      : baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), '');

  final String baseUrl;

  Future<List<Language>> fetchLanguages() async {
    final http.Response response;
    try {
      response = await http.get(Uri.parse('$baseUrl/api/languages'));
    } catch (exc) {
      throw BackendException('Could not reach backend at $baseUrl: $exc');
    }
    if (response.statusCode != 200) {
      throw BackendException('Failed to load languages (HTTP ${response.statusCode})');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => Language.fromJson(item as Map<String, dynamic>)).toList();
  }

  Future<ProcessResult> processImage({
    required Uint8List bytes,
    required String filename,
    required String sourceLang,
    required String targetLang,
  }) async {
    final uri = Uri.parse('$baseUrl/api/process');
    final request = http.MultipartRequest('POST', uri)
      ..fields['source_lang'] = sourceLang
      ..fields['target_lang'] = targetLang
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final http.Response response;
    try {
      final streamedResponse = await request.send();
      response = await http.Response.fromStream(streamedResponse);
    } catch (exc) {
      throw BackendException('Could not reach backend at $baseUrl: $exc');
    }

    if (response.statusCode != 200) {
      throw BackendException('Processing failed (HTTP ${response.statusCode}): ${_extractDetail(response.body)}');
    }
    return ProcessResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  String _extractDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {
      // Fall through and return the raw body below.
    }
    return body;
  }

  /// Creates an ESP32 capture job. Flutter then tells the ESP32 to capture and
  /// upload directly to this job (see Esp32Client.triggerCapture).
  Future<String> createJob({required String sourceLang, required String targetLang}) async {
    final uri = Uri.parse('$baseUrl/api/v1/jobs');
    final http.Response response;
    try {
      response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'source_lang': sourceLang, 'target_lang': targetLang}),
      );
    } catch (exc) {
      throw BackendException('Could not reach backend at $baseUrl: $exc');
    }
    if (response.statusCode != 200) {
      throw BackendException('Failed to create job (HTTP ${response.statusCode}): ${_extractDetail(response.body)}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['job_id'] as String;
  }

  /// Polls the status of a job created via [createJob].
  Future<JobStatus> fetchJob(String jobId) async {
    final http.Response response;
    try {
      response = await http.get(Uri.parse('$baseUrl/api/v1/jobs/$jobId'));
    } catch (exc) {
      throw BackendException('Could not reach backend at $baseUrl: $exc');
    }
    if (response.statusCode != 200) {
      throw BackendException('Failed to fetch job (HTTP ${response.statusCode}): ${_extractDetail(response.body)}');
    }
    return JobStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
